#!/usr/bin/env python3
"""Regenerates lib/src/features/multichain/domain/generated/multichain_generated.dart.

Sources:
  - EVM chains:   https://chainid.network/chains.json (ethereum-lists/chains)
  - Cosmos chains: https://chains.cosmos.directory/ (cosmos/chain-registry
    aggregate) + per-chain chain.json from cosmos/chain-registry for gas prices

Filters:
  - EVM: mainnets only (name-based testnet exclusion), not deprecated, at
    least one keyless https RPC (no ${...} placeholders); curated built-in
    chain ids are skipped.
  - Cosmos: status live, network_type mainnet, any integer slip44. Chains
    with slip44 60 are ethermint/Injective-style (keccak addresses + keccak
    sign digests); the app derives per-chain from the emitted slip44.

Usage: python3 scripts/gen-multichain-registry.py
"""

import json
import re
import urllib.request
from concurrent.futures import ThreadPoolExecutor

OUT = "lib/src/features/multichain/domain/generated/multichain_generated.dart"

# Chain ids / registry paths already curated by hand in multichain_chain.dart.
CURATED_EVM_IDS = {1, 8453, 42161, 137, 56, 143}
CURATED_COSMOS_PATHS = {"cosmoshub", "osmosis", "celestia", "noble"}
# Names reserved by built-in entries (route namespace).
RESERVED_NAMES = {
    "btc", "doge", "eth", "base", "arbitrum", "polygon", "bnb", "monad",
    "cosmos", "osmosis", "celestia", "noble", "sol", "sui", "aptos",
}

TESTNET_RE = re.compile(
    r"test|devnet|sepolia|goerli|holesky|kovan|rinkeby|ropsten", re.I
)
MAX_RPCS = 3


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "vizor-registry-gen"})
    with urllib.request.urlopen(req, timeout=60) as f:
        return json.load(f)


def dart_str(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$") + "'"


def clean_rpcs(chain):
    out = []
    for rpc in chain.get("rpc", []):
        if (
            isinstance(rpc, str)
            and rpc.startswith("https://")
            and "${" not in rpc
            and "API_KEY" not in rpc
        ):
            out.append(rpc.rstrip("/"))
    return out[:MAX_RPCS]


def gen_evm():
    chains = fetch_json("https://chainid.network/chains.json")
    entries = []
    for chain in sorted(chains, key=lambda c: c["chainId"]):
        if chain["chainId"] in CURATED_EVM_IDS:
            continue
        if chain.get("status") == "deprecated":
            continue
        if TESTNET_RE.search(chain.get("name", "") + chain.get("shortName", "")):
            continue
        rpcs = clean_rpcs(chain)
        if not rpcs:
            continue
        currency = chain.get("nativeCurrency") or {}
        symbol = currency.get("symbol") or "ETH"
        decimals = currency.get("decimals")
        if not isinstance(decimals, int) or decimals <= 0:
            continue
        entries.append(
            {
                "name": f"evm{chain['chainId']}",
                "displayName": chain["name"],
                "symbol": symbol,
                "decimals": decimals,
                "chainId": chain["chainId"],
                "rpcs": rpcs,
            }
        )
    return entries


def cosmos_gas_price(path):
    """average_gas_price of the primary fee token from the chain registry."""
    try:
        chain = fetch_json(
            f"https://raw.githubusercontent.com/cosmos/chain-registry/master/{path}/chain.json"
        )
    except Exception:
        return None
    tokens = (chain.get("fees") or {}).get("fee_tokens") or []
    if not tokens:
        return None
    token = tokens[0]
    for key in ("average_gas_price", "fixed_min_gas_price", "low_gas_price"):
        value = token.get(key)
        if isinstance(value, (int, float)) and value > 0:
            return {"denom": token.get("denom"), "price": float(value)}
    return {"denom": token.get("denom"), "price": 0.025}


def gen_cosmos():
    data = fetch_json("https://chains.cosmos.directory/")["chains"]
    candidates = [
        c
        for c in data
        if c.get("status") == "live"
        and c.get("network_type") == "mainnet"
        and isinstance(c.get("slip44"), int)
        and c.get("path") not in CURATED_COSMOS_PATHS
        and c.get("name") not in RESERVED_NAMES
        and c.get("chain_id")
        and c.get("bech32_prefix")
        and c.get("denom")
        and isinstance(c.get("decimals"), int)
    ]
    with ThreadPoolExecutor(max_workers=16) as pool:
        fee_infos = list(pool.map(lambda c: cosmos_gas_price(c["path"]), candidates))

    entries = []
    for chain, fee in sorted(
        zip(candidates, fee_infos), key=lambda pair: pair[0]["path"]
    ):
        denom = chain["denom"]
        gas_price = 0.025
        # Only trust the registry gas price when it prices the display denom;
        # otherwise fall back to the conservative default.
        if fee and fee.get("denom") == denom and fee.get("price"):
            gas_price = fee["price"]
        rests = [f"https://rest.cosmos.directory/{chain['path']}"]
        for api in ((chain.get("best_apis") or {}).get("rest") or [])[:2]:
            address = (api.get("address") or "").rstrip("/")
            if address.startswith("https://") and address not in rests:
                rests.append(address)
        entries.append(
            {
                "name": chain["path"],
                "displayName": chain.get("pretty_name") or chain["path"],
                "symbol": chain.get("symbol") or denom.upper(),
                "decimals": chain["decimals"],
                "chainId": chain["chain_id"],
                "hrp": chain["bech32_prefix"],
                "denom": denom,
                "slip44": chain["slip44"],
                "gasPrice": gas_price,
                "rests": rests[:MAX_RPCS],
            }
        )
    return entries


def main():
    evm = gen_evm()
    cosmos = gen_cosmos()

    lines = [
        "// GENERATED by scripts/gen-multichain-registry.py — do not edit.",
        "//",
        "// EVM chains: ethereum-lists/chains (chainid.network), mainnets with",
        "// keyless https RPCs. Cosmos chains: cosmos/chain-registry via",
        "// cosmos.directory, live mainnets (slip44 60 = ethermint-style keys).",
        "",
        "import '../multichain_chain.dart';",
        "",
        f"/// {len(evm)} generated EVM chains.",
        "const List<MultichainChain> kGeneratedEvmChains = [",
    ]
    for c in evm:
        lines += [
            "  MultichainChain(",
            f"    name: {dart_str(c['name'])},",
            "    family: MultichainFamily.evm,",
            f"    symbol: {dart_str(c['symbol'])},",
            f"    displayName: {dart_str(c['displayName'])},",
            f"    decimals: {c['decimals']},",
            f"    evmChainId: {c['chainId']},",
            "    endpoints: [",
            *[f"      {dart_str(r)}," for r in c["rpcs"]],
            "    ],",
            "  ),",
        ]
    lines += [
        "];",
        "",
        f"/// {len(cosmos)} generated Cosmos SDK chains.",
        "const List<MultichainChain> kGeneratedCosmosChains = [",
    ]
    for c in cosmos:
        lines += [
            "  MultichainChain(",
            f"    name: {dart_str(c['name'])},",
            "    family: MultichainFamily.cosmos,",
            f"    symbol: {dart_str(c['symbol'])},",
            f"    displayName: {dart_str(c['displayName'])},",
            f"    decimals: {c['decimals']},",
            f"    cosmosChainId: {dart_str(c['chainId'])},",
            f"    cosmosHrp: {dart_str(c['hrp'])},",
            f"    cosmosDenom: {dart_str(c['denom'])},",
            f"    cosmosGasPrice: {c['gasPrice']},",
            f"    cosmosSlip44: {c['slip44']},",
            "    endpoints: [",
            *[f"      {dart_str(r)}," for r in c["rests"]],
            "    ],",
            "  ),",
        ]
    lines += ["];", ""]

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"wrote {OUT}: {len(evm)} EVM + {len(cosmos)} Cosmos chains")


if __name__ == "__main__":
    main()
