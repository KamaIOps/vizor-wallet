import 'generated/multichain_generated.dart';

/// Chain families sharing one signing/networking implementation. Adding a
/// chain within an existing family is a registry entry; a new family needs
/// a Rust signer and a Dart service.
enum MultichainFamily {
  /// Bitcoin-style UTXO chains (Esplora/Blockbook REST).
  utxo,

  /// EVM chains: one shared address (m/44'/60'/0'/0/0), EIP-1559 signing
  /// selected by chain id, JSON-RPC endpoints.
  evm,

  /// Cosmos SDK chains (LCD REST, SIGN_MODE_DIRECT).
  cosmos,

  /// Solana (JSON-RPC).
  sol,

  /// Sui (JSON-RPC, programmable transaction blocks).
  sui,

  /// Aptos (fullnode REST, entry-function payloads).
  aptos,
}

/// A non-Zcash chain supported by the multichain feature.
///
/// These are transparent public chains: balances and activity at these
/// addresses are visible to anyone, and balance queries reveal the address
/// to the endpoint operator. Endpoints are keyless public services; requests
/// are made on demand only (never background-polled) and rotate to the next
/// endpoint on failure. ZEC data never appears in any of these requests.
///
/// [builtIns] are the major chains every user sees; [catalog] additionally
/// contains every generated EVM and Cosmos SDK registry entry, which users
/// can enable manually from the add-chain screen.
class MultichainChain {
  const MultichainChain({
    required this.name,
    required this.family,
    required this.symbol,
    required this.displayName,
    required this.decimals,
    required this.endpoints,
    this.evmChainId,
    this.cosmosChainId,
    this.cosmosHrp,
    this.cosmosDenom,
    this.cosmosGasPrice,
    this.cosmosSlip44,
  });

  /// Stable identifier used in routes and persistence — never rename one.
  final String name;

  final MultichainFamily family;
  final String symbol;
  final String displayName;
  final int decimals;
  final List<String> endpoints;

  /// EIP-155 chain id; set exactly for [MultichainFamily.evm] chains.
  final int? evmChainId;

  /// Cosmos SDK chain parameters; set exactly for
  /// [MultichainFamily.cosmos] chains. Gas price is in the chain's minimal
  /// denom per gas unit (chain-registry average gas price).
  final String? cosmosChainId;
  final String? cosmosHrp;
  final String? cosmosDenom;
  final double? cosmosGasPrice;

  /// Registry SLIP-44 coin type (118 standard, 60 ethermint/Injective,
  /// 529 Secret, 931 THORChain, ...). The default derivation path; users can
  /// select an alternative candidate per chain.
  final int? cosmosSlip44;

  /// Ethermint/Injective-style chain: keccak-derived addresses and keccak
  /// sign-doc digests, regardless of which coin type the user selected for
  /// the HD path (the format follows the chain, like Keplr).
  bool get cosmosUsesEthKey => cosmosSlip44 == 60;

  /// Signer pubkey Any type url, resolved like Keplr's
  /// getCosmosPubKeyTypeUrl (background/tx-executor/utils/cosmos.ts).
  String get cosmosPubkeyTypeUrl {
    if (!cosmosUsesEthKey) return '/cosmos.crypto.secp256k1.PubKey';
    if (cosmosChainId!.startsWith('injective')) {
      return '/injective.crypto.v1beta1.ethsecp256k1.PubKey';
    }
    if (cosmosChainId!.startsWith('stratos')) {
      return '/stratos.crypto.v1.ethsecp256k1.PubKey';
    }
    return '/ethermint.crypto.v1.ethsecp256k1.PubKey';
  }

  /// Derivation coin types offered for this cosmos chain: the registry
  /// default first, then the common alternatives (118 standard, 60
  /// eth-style) — one seed can hold funds under several of these.
  List<int> get cosmosCoinTypeCandidates {
    final seen = <int>{};
    return [
      for (final candidate in [cosmosSlip44!, 118, 60])
        if (seen.add(candidate)) candidate,
    ];
  }

  static const btc = MultichainChain(
    name: 'btc',
    family: MultichainFamily.utxo,
    symbol: 'BTC',
    displayName: 'Bitcoin',
    decimals: 8,
    // Esplora-compatible REST APIs.
    endpoints: [
      'https://blockstream.info/api',
      'https://mempool.space/api',
    ],
  );

  static const doge = MultichainChain(
    name: 'doge',
    family: MultichainFamily.utxo,
    symbol: 'DOGE',
    displayName: 'Dogecoin',
    decimals: 8,
    // BlockCypher public API (Trezor's public Blockbook instances are
    // Cloudflare-gated for non-browser clients; verified 2026-07).
    endpoints: [
      'https://api.blockcypher.com/v1/doge/main',
    ],
  );

  static const eth = MultichainChain(
    name: 'eth',
    family: MultichainFamily.evm,
    symbol: 'ETH',
    displayName: 'Ethereum',
    decimals: 18,
    evmChainId: 1,
    // JSON-RPC.
    endpoints: [
      'https://ethereum-rpc.publicnode.com',
      'https://eth.llamarpc.com',
      'https://cloudflare-eth.com',
    ],
  );

  static const base = MultichainChain(
    name: 'base',
    family: MultichainFamily.evm,
    symbol: 'ETH',
    displayName: 'Base',
    decimals: 18,
    evmChainId: 8453,
    endpoints: [
      'https://mainnet.base.org',
      'https://base-rpc.publicnode.com',
    ],
  );

  static const arbitrum = MultichainChain(
    name: 'arbitrum',
    family: MultichainFamily.evm,
    symbol: 'ETH',
    displayName: 'Arbitrum One',
    decimals: 18,
    evmChainId: 42161,
    endpoints: [
      'https://arb1.arbitrum.io/rpc',
      'https://arbitrum-one-rpc.publicnode.com',
    ],
  );

  static const polygon = MultichainChain(
    name: 'polygon',
    family: MultichainFamily.evm,
    symbol: 'POL',
    displayName: 'Polygon',
    decimals: 18,
    evmChainId: 137,
    endpoints: [
      'https://polygon-rpc.com',
      'https://polygon-bor-rpc.publicnode.com',
    ],
  );

  static const bnb = MultichainChain(
    name: 'bnb',
    family: MultichainFamily.evm,
    symbol: 'BNB',
    displayName: 'BNB Smart Chain',
    decimals: 18,
    evmChainId: 56,
    endpoints: [
      'https://bsc-dataseed.bnbchain.org',
      'https://bsc-rpc.publicnode.com',
    ],
  );

  static const monad = MultichainChain(
    name: 'monad',
    family: MultichainFamily.evm,
    symbol: 'MON',
    displayName: 'Monad',
    decimals: 18,
    evmChainId: 143,
    endpoints: [
      'https://rpc.monad.xyz',
      'https://monad.drpc.org',
    ],
  );

  static const cosmos = MultichainChain(
    name: 'cosmos',
    family: MultichainFamily.cosmos,
    symbol: 'ATOM',
    displayName: 'Cosmos Hub',
    decimals: 6,
    cosmosChainId: 'cosmoshub-4',
    cosmosHrp: 'cosmos',
    cosmosDenom: 'uatom',
    cosmosGasPrice: 0.025,
    cosmosSlip44: 118,
    // Cosmos SDK REST (LCD).
    endpoints: [
      'https://cosmos-rest.publicnode.com',
      'https://rest.cosmos.directory/cosmoshub',
    ],
  );

  static const osmosis = MultichainChain(
    name: 'osmosis',
    family: MultichainFamily.cosmos,
    symbol: 'OSMO',
    displayName: 'Osmosis',
    decimals: 6,
    cosmosChainId: 'osmosis-1',
    cosmosHrp: 'osmo',
    cosmosDenom: 'uosmo',
    // Keplr chain-registry gasPriceStep.average (fee market floor is lower).
    cosmosGasPrice: 0.1,
    cosmosSlip44: 118,
    endpoints: [
      'https://osmosis-rest.publicnode.com',
      'https://rest.cosmos.directory/osmosis',
    ],
  );

  static const celestia = MultichainChain(
    name: 'celestia',
    family: MultichainFamily.cosmos,
    symbol: 'TIA',
    displayName: 'Celestia',
    decimals: 6,
    cosmosChainId: 'celestia',
    cosmosHrp: 'celestia',
    cosmosDenom: 'utia',
    cosmosGasPrice: 0.02,
    cosmosSlip44: 118,
    endpoints: [
      'https://celestia-rest.publicnode.com',
      'https://rest.cosmos.directory/celestia',
    ],
  );

  static const noble = MultichainChain(
    name: 'noble',
    family: MultichainFamily.cosmos,
    symbol: 'USDC',
    displayName: 'Noble',
    decimals: 6,
    cosmosChainId: 'noble-1',
    cosmosHrp: 'noble',
    cosmosDenom: 'uusdc',
    cosmosGasPrice: 0.1,
    cosmosSlip44: 118,
    endpoints: [
      'https://rest.cosmos.directory/noble',
      'https://noble-api.polkachu.com',
    ],
  );

  static const sol = MultichainChain(
    name: 'sol',
    family: MultichainFamily.sol,
    symbol: 'SOL',
    displayName: 'Solana',
    decimals: 9,
    // JSON-RPC.
    endpoints: [
      'https://api.mainnet-beta.solana.com',
      'https://solana-rpc.publicnode.com',
    ],
  );

  static const sui = MultichainChain(
    name: 'sui',
    family: MultichainFamily.sui,
    symbol: 'SUI',
    displayName: 'Sui',
    decimals: 9,
    // JSON-RPC.
    endpoints: [
      'https://fullnode.mainnet.sui.io',
      'https://sui-rpc.publicnode.com',
    ],
  );

  static const aptos = MultichainChain(
    name: 'aptos',
    family: MultichainFamily.aptos,
    symbol: 'APT',
    displayName: 'Aptos',
    decimals: 8,
    // Fullnode REST v1.
    endpoints: [
      'https://api.mainnet.aptoslabs.com/v1',
      'https://aptos-rest.publicnode.com/v1',
    ],
  );

  /// Major chains shown to every user by default.
  static const List<MultichainChain> builtIns = [
    btc,
    doge,
    eth,
    base,
    arbitrum,
    polygon,
    bnb,
    monad,
    cosmos,
    osmosis,
    celestia,
    noble,
    sol,
    sui,
    aptos,
  ];

  /// The full add-able catalog: built-ins plus every generated EVM and
  /// Cosmos SDK registry chain.
  static final List<MultichainChain> catalog = List.unmodifiable([
    ...builtIns,
    ...kGeneratedEvmChains,
    ...kGeneratedCosmosChains,
  ]);

  static final Map<String, MultichainChain> _byName = {
    for (final chain in catalog) chain.name: chain,
  };

  /// Catalog lookup by stable [name]; null for unknown names (e.g. a
  /// persisted chain that was removed from the registry).
  static MultichainChain? byName(String name) => _byName[name];

  /// Smallest-unit name shown next to fees (sats, wei, uatom, lamports).
  String get baseUnitName => switch (family) {
    MultichainFamily.utxo => this == MultichainChain.doge ? 'koinu' : 'sats',
    MultichainFamily.evm => 'wei',
    MultichainFamily.cosmos => cosmosDenom!,
    MultichainFamily.sol => 'lamports',
    MultichainFamily.sui => 'mist',
    MultichainFamily.aptos => 'octas',
  };

  /// The version component of a Cosmos chain id (`{identifier}-{version}`),
  /// 0 when the chain id has no `-N` suffix (e.g. "celestia"). Used as the
  /// IBC timeout-height revision number, matching Keplr's ChainIdHelper.
  int get cosmosChainIdVersion {
    final match = RegExp(r'-(\d+)$').firstMatch(cosmosChainId!);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  @override
  String toString() => 'MultichainChain($name)';
}

/// One displayable account on a chain: the chain plus its derivation
/// variant. `coinType` selects the HD path on cosmos chains; `btcLegacy`
/// selects Bitcoin's BIP-44 P2PKH derivation instead of BIP-84 P2WPKH.
/// One seed can hold funds under several variants of the same chain; funded
/// variants are surfaced automatically as separate accounts.
typedef MultichainAccountRef = ({
  MultichainChain chain,
  int? coinType,
  bool btcLegacy,
});

/// The ref for a chain's default (or user-selected) derivation.
MultichainAccountRef multichainRefFor(
  MultichainChain chain, {
  int? coinType,
  bool btcLegacy = false,
}) => (
  chain: chain,
  coinType: chain.family == MultichainFamily.cosmos
      ? (coinType ?? chain.cosmosSlip44)
      : null,
  btcLegacy: btcLegacy,
);

/// Alternate derivations worth probing for funds next to [selected].
List<MultichainAccountRef> multichainVariantRefs(
  MultichainAccountRef selected,
) {
  final chain = selected.chain;
  if (chain == MultichainChain.btc) {
    return [multichainRefFor(chain, btcLegacy: !selected.btcLegacy)];
  }
  if (chain.family == MultichainFamily.cosmos) {
    return [
      for (final candidate in chain.cosmosCoinTypeCandidates)
        if (candidate != selected.coinType)
          multichainRefFor(chain, coinType: candidate),
    ];
  }
  return const [];
}

/// Short derivation-path label shown on variant rows and selectors.
String multichainDerivationLabel(MultichainAccountRef accountRef) {
  if (accountRef.chain == MultichainChain.btc) {
    return accountRef.btcLegacy ? "m/44'/0'" : "m/84'/0'";
  }
  if (accountRef.chain.family == MultichainFamily.cosmos) {
    return "m/44'/${accountRef.coinType}'";
  }
  return '';
}

/// A directed ics-20 transfer route. `channelId` lives on the SOURCE chain.
///
/// Channels verified on-chain 2026-07-16 (STATE_OPEN, counterparty matched
/// from both sides via LCD `/ibc/core/channel/v1/channels/...`), matching
/// cosmos/chain-registry `_IBC` data.
class IbcRoute {
  const IbcRoute(this.from, this.to, this.channelId);

  final MultichainChain from;
  final MultichainChain to;
  final String channelId;
}

const List<IbcRoute> kIbcRoutes = [
  IbcRoute(MultichainChain.cosmos, MultichainChain.osmosis, 'channel-141'),
  IbcRoute(MultichainChain.osmosis, MultichainChain.cosmos, 'channel-0'),
  IbcRoute(MultichainChain.cosmos, MultichainChain.celestia, 'channel-1879'),
  IbcRoute(MultichainChain.celestia, MultichainChain.cosmos, 'channel-278'),
  IbcRoute(MultichainChain.cosmos, MultichainChain.noble, 'channel-536'),
  IbcRoute(MultichainChain.noble, MultichainChain.cosmos, 'channel-4'),
];

/// IBC destinations reachable from [source] (empty for non-cosmos chains).
List<IbcRoute> ibcRoutesFrom(MultichainChain source) =>
    [for (final route in kIbcRoutes) if (route.from == source) route];

/// Formats a base-unit amount as a decimal coin string (no trailing zeros).
String formatMultichainAmount(BigInt baseUnits, int decimals) {
  final divisor = BigInt.from(10).pow(decimals);
  final whole = baseUnits ~/ divisor;
  final frac = (baseUnits % divisor).toString().padLeft(decimals, '0');
  final trimmed = frac.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.isEmpty ? '$whole' : '$whole.$trimmed';
}

/// Parses a user-entered decimal coin amount into base units.
/// Integer-only math (mirrors the ZEC zatoshi parsing rule: no doubles).
BigInt? parseMultichainAmount(String text, int decimals) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final match = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(trimmed);
  if (match == null) return null;
  final whole = match.group(1)!;
  final frac = match.group(2) ?? '';
  if (frac.length > decimals) return null;
  final wholeUnits = BigInt.parse(whole) * BigInt.from(10).pow(decimals);
  final fracUnits = frac.isEmpty
      ? BigInt.zero
      : BigInt.parse(frac.padRight(decimals, '0'));
  return wholeUnits + fracUnits;
}
