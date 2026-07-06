/// Non-Zcash chains supported by the multichain feature.
///
/// These are transparent public chains: balances and activity at these
/// addresses are visible to anyone, and balance queries reveal the address
/// to the endpoint operator. Endpoints are keyless public services; requests
/// are made on demand only (never background-polled) and rotate to the next
/// endpoint on failure. ZEC data never appears in any of these requests.
enum MultichainChain {
  btc(
    symbol: 'BTC',
    displayName: 'Bitcoin',
    decimals: 8,
    // Esplora-compatible REST APIs.
    endpoints: [
      'https://blockstream.info/api',
      'https://mempool.space/api',
    ],
  ),
  eth(
    symbol: 'ETH',
    displayName: 'Ethereum',
    decimals: 18,
    // JSON-RPC.
    endpoints: [
      'https://ethereum-rpc.publicnode.com',
      'https://eth.llamarpc.com',
      'https://cloudflare-eth.com',
    ],
  ),
  cosmos(
    symbol: 'ATOM',
    displayName: 'Cosmos Hub',
    decimals: 6,
    // Cosmos SDK REST (LCD).
    endpoints: [
      'https://cosmos-rest.publicnode.com',
      'https://rest.cosmos.directory/cosmoshub',
    ],
  ),
  sol(
    symbol: 'SOL',
    displayName: 'Solana',
    decimals: 9,
    // JSON-RPC.
    endpoints: [
      'https://api.mainnet-beta.solana.com',
      'https://solana-rpc.publicnode.com',
    ],
  );

  const MultichainChain({
    required this.symbol,
    required this.displayName,
    required this.decimals,
    required this.endpoints,
  });

  final String symbol;
  final String displayName;
  final int decimals;
  final List<String> endpoints;

  /// Smallest-unit name shown next to fees (sats, wei, uatom, lamports).
  String get baseUnitName => switch (this) {
    MultichainChain.btc => 'sats',
    MultichainChain.eth => 'wei',
    MultichainChain.cosmos => 'uatom',
    MultichainChain.sol => 'lamports',
  };
}

/// Ethereum mainnet chain id (EIP-155).
const int kEthMainnetChainId = 1;

/// Cosmos Hub chain id and bech32 prefix.
const String kCosmosHubChainId = 'cosmoshub-4';
const String kCosmosHubHrp = 'cosmos';
const String kCosmosHubDenom = 'uatom';

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
