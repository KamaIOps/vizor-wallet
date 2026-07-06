import '../../../rust/api/chains.dart' as rust;
import '../domain/multichain_chain.dart';
import 'multichain_rpc.dart';

/// Everything a chain send needs beyond the signed bytes, fetched on demand.
class MultichainSendPreview {
  const MultichainSendPreview({
    required this.feeBaseUnits,
    required this.feeText,
    this.context,
  });

  /// Estimated fee in the chain's base units.
  final BigInt feeBaseUnits;

  /// Human-readable fee line (coin units).
  final String feeText;

  /// Opaque per-chain data threaded from preview to broadcast so the fee the
  /// user approved is the fee that is signed.
  final Object? context;
}

/// Per-chain networking + signing orchestration.
///
/// Balance/prereq queries and broadcast go to the chain's public endpoints;
/// signing happens in Rust with the account mnemonic (which is read from
/// secure storage only at the moment of signing, mirroring the ZEC send
/// path).
abstract class MultichainService {
  MultichainService(this.chain, this.rpc);

  final MultichainChain chain;
  final MultichainRpc rpc;

  Future<BigInt> fetchBalance(String address);

  Future<MultichainSendPreview> previewSend({
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  });

  /// Signs and broadcasts; returns the tx hash/id.
  Future<String> send({
    required String mnemonic,
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
    required MultichainSendPreview preview,
  });

  String formatAmount(BigInt baseUnits) =>
      '${formatMultichainAmount(baseUnits, chain.decimals)} ${chain.symbol}';
}

// ======================== Ethereum ========================

class EthService extends MultichainService {
  EthService(MultichainRpc rpc) : super(MultichainChain.eth, rpc);

  static const _transferGasLimit = 21000;

  @override
  Future<BigInt> fetchBalance(String address) async {
    final result =
        await rpc.jsonRpc(chain.endpoints, 'eth_getBalance', [address, 'latest']);
    return _hexToBigInt(result);
  }

  @override
  Future<MultichainSendPreview> previewSend({
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  }) async {
    final nonceHex = await rpc.jsonRpc(
      chain.endpoints,
      'eth_getTransactionCount',
      [fromAddress, 'pending'],
    );
    final block = await rpc.jsonRpc(
      chain.endpoints,
      'eth_getBlockByNumber',
      ['latest', false],
    );
    if (block is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed block response');
    }
    final baseFee = _hexToBigInt(block['baseFeePerGas']);
    BigInt priority;
    try {
      priority = _hexToBigInt(
        await rpc.jsonRpc(chain.endpoints, 'eth_maxPriorityFeePerGas', []),
      );
    } on MultichainRpcException {
      priority = BigInt.from(1500000000); // 1.5 gwei fallback
    }
    // Standard headroom: fee cap = 2×base + tip (survives base-fee spikes;
    // unused headroom is not charged).
    final maxFee = baseFee * BigInt.two + priority;
    final worstCaseFee = maxFee * BigInt.from(_transferGasLimit);
    return MultichainSendPreview(
      feeBaseUnits: worstCaseFee,
      feeText: '≤ ${formatAmount(worstCaseFee)}',
      context: _EthFeeContext(
        nonce: _hexToBigInt(nonceHex).toInt(),
        maxPriorityFeePerGas: priority,
        maxFeePerGas: maxFee,
      ),
    );
  }

  @override
  Future<String> send({
    required String mnemonic,
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
    required MultichainSendPreview preview,
  }) async {
    final fees = preview.context! as _EthFeeContext;
    final rawTx = await rust.signEthTransaction(
      mnemonic: mnemonic,
      chainId: BigInt.from(kEthMainnetChainId),
      nonce: BigInt.from(fees.nonce),
      maxPriorityFeePerGasWei: fees.maxPriorityFeePerGas.toString(),
      maxFeePerGasWei: fees.maxFeePerGas.toString(),
      gasLimit: BigInt.from(_transferGasLimit),
      to: toAddress,
      valueWei: amountBaseUnits.toString(),
    );
    final hash =
        await rpc.jsonRpc(chain.endpoints, 'eth_sendRawTransaction', [rawTx]);
    return hash as String;
  }

  static BigInt _hexToBigInt(Object? hex) {
    if (hex is! String || !hex.startsWith('0x')) {
      throw MultichainRpcException('Expected hex quantity, got: $hex');
    }
    return BigInt.parse(hex.substring(2).isEmpty ? '0' : hex.substring(2),
        radix: 16);
  }
}

class _EthFeeContext {
  const _EthFeeContext({
    required this.nonce,
    required this.maxPriorityFeePerGas,
    required this.maxFeePerGas,
  });

  final int nonce;
  final BigInt maxPriorityFeePerGas;
  final BigInt maxFeePerGas;
}

// ======================== Bitcoin ========================

class BtcService extends MultichainService {
  BtcService(MultichainRpc rpc) : super(MultichainChain.btc, rpc);

  // P2WPKH weight-unit estimate: ~10.5 vB overhead + 68 vB per input +
  // 31 vB per output (industry-standard approximation, matches Keplr's).
  static int _estimateVsize(int inputs, int outputs) =>
      11 + 68 * inputs + 31 * outputs;

  @override
  Future<BigInt> fetchBalance(String address) async {
    final utxos = await _confirmedUtxos(address);
    return utxos.fold<BigInt>(
      BigInt.zero,
      (sum, u) => sum + BigInt.from(u.valueSats),
    );
  }

  Future<List<_BtcUtxo>> _confirmedUtxos(String address) async {
    final result = await rpc.get(chain.endpoints, '/address/$address/utxo');
    if (result is! List) {
      throw MultichainRpcException('Malformed UTXO response');
    }
    return [
      for (final entry in result.cast<Map<String, dynamic>>())
        if ((entry['status'] as Map<String, dynamic>?)?['confirmed'] == true)
          _BtcUtxo(
            txid: entry['txid'] as String,
            vout: entry['vout'] as int,
            valueSats: entry['value'] as int,
          ),
    ];
  }

  Future<double> _feeRate() async {
    // Esplora fee-estimates: { "1": satsPerVb, "3": …, "6": … }.
    final estimates = await rpc.get(chain.endpoints, '/fee-estimates');
    if (estimates is Map<String, dynamic>) {
      final rate = estimates['3'] ?? estimates['6'] ?? estimates['1'];
      if (rate is num && rate > 0) return rate.toDouble();
    }
    return 2.0; // conservative floor, sats/vB
  }

  @override
  Future<MultichainSendPreview> previewSend({
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  }) async {
    final utxos = await _confirmedUtxos(fromAddress);
    final rate = await _feeRate();
    final selection = _select(utxos, amountBaseUnits, rate);
    return MultichainSendPreview(
      feeBaseUnits: selection.feeSats,
      feeText: formatAmount(selection.feeSats),
      context: selection,
    );
  }

  /// Largest-first selection (same strategy as Keplr's stores-bitcoin).
  _BtcSelection _select(List<_BtcUtxo> utxos, BigInt amount, double rate) {
    final sorted = [...utxos]..sort((a, b) => b.valueSats - a.valueSats);
    final picked = <_BtcUtxo>[];
    var total = BigInt.zero;
    for (final utxo in sorted) {
      picked.add(utxo);
      total += BigInt.from(utxo.valueSats);
      // Try both shapes: with and without change output.
      final feeWithChange =
          BigInt.from((_estimateVsize(picked.length, 2) * rate).ceil());
      final feeNoChange =
          BigInt.from((_estimateVsize(picked.length, 1) * rate).ceil());
      const dustLimit = 546;
      final change = total - amount - feeWithChange;
      if (change >= BigInt.from(dustLimit)) {
        return _BtcSelection(
          utxos: picked,
          feeSats: feeWithChange,
          changeSats: change,
        );
      }
      if (total - amount - feeNoChange >= BigInt.zero) {
        // Remainder below dust: fold it into the fee, no change output.
        return _BtcSelection(
          utxos: picked,
          feeSats: total - amount,
          changeSats: BigInt.zero,
        );
      }
    }
    throw MultichainRpcException('Insufficient confirmed balance for amount + fee');
  }

  @override
  Future<String> send({
    required String mnemonic,
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
    required MultichainSendPreview preview,
  }) async {
    final selection = preview.context! as _BtcSelection;
    final rawTx = await rust.signBtcTransaction(
      mnemonic: mnemonic,
      utxos: [
        for (final u in selection.utxos)
          rust.ApiBtcUtxo(
            txid: u.txid,
            vout: u.vout,
            valueSats: BigInt.from(u.valueSats),
          ),
      ],
      toAddress: toAddress,
      amountSats: amountBaseUnits,
      changeSats: selection.changeSats,
    );
    final txid = await rpc.postText(chain.endpoints, '/tx', rawTx);
    return (txid as String).trim();
  }
}

class _BtcUtxo {
  const _BtcUtxo({
    required this.txid,
    required this.vout,
    required this.valueSats,
  });

  final String txid;
  final int vout;
  final int valueSats;
}

class _BtcSelection {
  const _BtcSelection({
    required this.utxos,
    required this.feeSats,
    required this.changeSats,
  });

  final List<_BtcUtxo> utxos;
  final BigInt feeSats;
  final BigInt changeSats;
}

// ======================== Cosmos Hub ========================

class CosmosService extends MultichainService {
  CosmosService(MultichainRpc rpc) : super(MultichainChain.cosmos, rpc);

  // Keplr's legacy default for bank sends is 80k gas; 100k adds headroom
  // without simulation. Fee = gas × average gasPriceStep (0.025 uatom).
  static const _gasLimit = 100000;
  static const _gasPrice = 0.025;

  @override
  Future<BigInt> fetchBalance(String address) async {
    final result = await rpc.get(
      chain.endpoints,
      '/cosmos/bank/v1beta1/balances/$address',
    );
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed balances response');
    }
    final balances = (result['balances'] as List? ?? const []);
    for (final coin in balances.cast<Map<String, dynamic>>()) {
      if (coin['denom'] == kCosmosHubDenom) {
        return BigInt.parse(coin['amount'] as String);
      }
    }
    return BigInt.zero;
  }

  @override
  Future<MultichainSendPreview> previewSend({
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  }) async {
    final account = await rpc.get(
      chain.endpoints,
      '/cosmos/auth/v1beta1/accounts/$fromAddress',
    );
    final base = _baseAccount(account);
    final fee = BigInt.from((_gasLimit * _gasPrice).ceil());
    return MultichainSendPreview(
      feeBaseUnits: fee,
      feeText: formatAmount(fee),
      context: base,
    );
  }

  /// Unwraps BaseAccount fields from the auth response (handles the plain
  /// BaseAccount shape and vesting/module accounts nesting `base_account`).
  _CosmosAccount _baseAccount(Object? response) {
    if (response is! Map<String, dynamic>) {
      throw MultichainRpcException(
        'Account not found on chain (fund it before sending)',
      );
    }
    Object? account = response['account'];
    while (account is Map<String, dynamic>) {
      if (account.containsKey('account_number')) {
        return _CosmosAccount(
          accountNumber: BigInt.parse(account['account_number'] as String),
          sequence: BigInt.parse((account['sequence'] as String?) ?? '0'),
        );
      }
      account = account['base_account'] ?? account['base_vesting_account'];
    }
    throw MultichainRpcException('Unrecognized account response shape');
  }

  @override
  Future<String> send({
    required String mnemonic,
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
    required MultichainSendPreview preview,
  }) async {
    final account = preview.context! as _CosmosAccount;
    final txBase64 = await rust.signCosmosSend(
      mnemonic: mnemonic,
      chainId: kCosmosHubChainId,
      hrp: kCosmosHubHrp,
      accountNumber: account.accountNumber,
      sequence: account.sequence,
      toAddress: toAddress,
      amount: amountBaseUnits.toString(),
      denom: kCosmosHubDenom,
      feeAmount: preview.feeBaseUnits.toString(),
      feeDenom: kCosmosHubDenom,
      gasLimit: BigInt.from(_gasLimit),
      memo: '',
    );
    final result = await rpc.postJson(chain.endpoints, '/cosmos/tx/v1beta1/txs', {
      'tx_bytes': txBase64,
      'mode': 'BROADCAST_MODE_SYNC',
    });
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed broadcast response');
    }
    final txResponse = result['tx_response'] as Map<String, dynamic>?;
    final code = txResponse?['code'];
    if (code != null && code != 0) {
      throw MultichainRpcException(
        'Broadcast rejected: ${txResponse?['raw_log'] ?? 'code $code'}',
      );
    }
    return (txResponse?['txhash'] as String?) ?? '';
  }
}

class _CosmosAccount {
  const _CosmosAccount({required this.accountNumber, required this.sequence});

  final BigInt accountNumber;
  final BigInt sequence;
}

// ======================== Solana ========================

class SolService extends MultichainService {
  SolService(MultichainRpc rpc) : super(MultichainChain.sol, rpc);

  // Base fee for a single-signature transaction.
  static final _signatureFee = BigInt.from(5000);

  @override
  Future<BigInt> fetchBalance(String address) async {
    final result = await rpc.jsonRpc(chain.endpoints, 'getBalance', [address]);
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed balance response');
    }
    return BigInt.from(result['value'] as int);
  }

  @override
  Future<MultichainSendPreview> previewSend({
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  }) async {
    final result = await rpc.jsonRpc(chain.endpoints, 'getLatestBlockhash', [
      {'commitment': 'finalized'},
    ]);
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed blockhash response');
    }
    final blockhash =
        (result['value'] as Map<String, dynamic>)['blockhash'] as String;
    return MultichainSendPreview(
      feeBaseUnits: _signatureFee,
      feeText: formatAmount(_signatureFee),
      context: blockhash,
    );
  }

  @override
  Future<String> send({
    required String mnemonic,
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
    required MultichainSendPreview preview,
  }) async {
    final txBase64 = await rust.signSolTransfer(
      mnemonic: mnemonic,
      recentBlockhash: preview.context! as String,
      toAddress: toAddress,
      lamports: amountBaseUnits,
    );
    final signature = await rpc.jsonRpc(chain.endpoints, 'sendTransaction', [
      txBase64,
      {'encoding': 'base64'},
    ]);
    return signature as String;
  }
}

/// Service lookup by chain.
MultichainService multichainServiceFor(
  MultichainChain chain,
  MultichainRpc rpc,
) {
  return switch (chain) {
    MultichainChain.btc => BtcService(rpc),
    MultichainChain.eth => EthService(rpc),
    MultichainChain.cosmos => CosmosService(rpc),
    MultichainChain.sol => SolService(rpc),
  };
}
