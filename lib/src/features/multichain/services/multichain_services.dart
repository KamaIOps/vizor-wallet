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

// ======================== EVM chains ========================

/// One service for every EVM-family chain: same address and EIP-1559 signer,
/// selected by the chain's EIP-155 id.
class EthService extends MultichainService {
  EthService(super.chain, super.rpc)
    : assert(chain.family == MultichainFamily.evm && chain.evmChainId != null);

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
    final nonce = _hexToBigInt(nonceHex).toInt();

    // Chains that never adopted EIP-1559 have no baseFeePerGas: fall back to
    // a legacy (type-0) transfer priced by eth_gasPrice.
    if (block['baseFeePerGas'] == null) {
      final gasPrice = _hexToBigInt(
        await rpc.jsonRpc(chain.endpoints, 'eth_gasPrice', []),
      );
      final fee = gasPrice * BigInt.from(_transferGasLimit);
      return MultichainSendPreview(
        feeBaseUnits: fee,
        feeText: formatAmount(fee),
        context: _EthFeeContext.legacy(nonce: nonce, gasPrice: gasPrice),
      );
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
        nonce: nonce,
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
    final rawTx = fees.isLegacy
        ? await rust.signEthLegacyTransaction(
            mnemonic: mnemonic,
            chainId: BigInt.from(chain.evmChainId!),
            nonce: BigInt.from(fees.nonce),
            gasPriceWei: fees.gasPrice!.toString(),
            gasLimit: BigInt.from(_transferGasLimit),
            to: toAddress,
            valueWei: amountBaseUnits.toString(),
          )
        : await rust.signEthTransaction(
            mnemonic: mnemonic,
            chainId: BigInt.from(chain.evmChainId!),
            nonce: BigInt.from(fees.nonce),
            maxPriorityFeePerGasWei: fees.maxPriorityFeePerGas!.toString(),
            maxFeePerGasWei: fees.maxFeePerGas!.toString(),
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
  }) : gasPrice = null;

  const _EthFeeContext.legacy({required this.nonce, required this.gasPrice})
    : maxPriorityFeePerGas = null,
      maxFeePerGas = null;

  final int nonce;
  final BigInt? maxPriorityFeePerGas;
  final BigInt? maxFeePerGas;

  /// Set only for legacy (pre-EIP-1559) chains.
  final BigInt? gasPrice;

  bool get isLegacy => gasPrice != null;
}

// ======================== Bitcoin ========================

class BtcService extends MultichainService {
  BtcService(MultichainRpc rpc, {this.legacy = false})
    : super(MultichainChain.btc, rpc);

  /// Spend from the BIP-44 legacy P2PKH derivation instead of BIP-84.
  final bool legacy;

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
      legacy: legacy,
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

// ======================== Dogecoin ========================

/// Dogecoin over the BlockCypher public API (legacy P2PKH, no segwit).
class DogeService extends MultichainService {
  DogeService(MultichainRpc rpc) : super(MultichainChain.doge, rpc);

  // Legacy P2PKH size estimate: ~10 B overhead + 148 B per input +
  // 34 B per output.
  static int _estimateSize(int inputs, int outputs) =>
      10 + 148 * inputs + 34 * outputs;

  /// Recommended floor: 0.01 DOGE/kB (relay minimum is 0.001 DOGE/kB).
  static final _minFeePerKb = BigInt.from(1000000);

  /// Dust threshold: 0.01 DOGE.
  static final _dustKoinu = BigInt.from(1000000);

  @override
  Future<BigInt> fetchBalance(String address) async {
    final utxos = await _confirmedUtxos(address);
    return utxos.fold<BigInt>(
      BigInt.zero,
      (sum, u) => sum + BigInt.from(u.valueKoinu),
    );
  }

  Future<List<_DogeUtxo>> _confirmedUtxos(String address) async {
    final result = await rpc.get(
      chain.endpoints,
      '/addrs/$address?unspentOnly=true',
    );
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed UTXO response');
    }
    // BlockCypher separates confirmed (txrefs) from unconfirmed refs.
    final refs = (result['txrefs'] as List? ?? const []);
    return [
      for (final entry in refs.cast<Map<String, dynamic>>())
        if ((entry['confirmations'] as int? ?? 0) > 0)
          _DogeUtxo(
            txid: entry['tx_hash'] as String,
            vout: entry['tx_output_n'] as int,
            valueKoinu: entry['value'] as int,
          ),
    ];
  }

  Future<BigInt> _feePerKb() async {
    final info = await rpc.get(chain.endpoints, '');
    if (info is Map<String, dynamic>) {
      final medium = info['medium_fee_per_kb'];
      if (medium is int && medium > 0) {
        final fetched = BigInt.from(medium);
        return fetched > _minFeePerKb ? fetched : _minFeePerKb;
      }
    }
    return _minFeePerKb;
  }

  @override
  Future<MultichainSendPreview> previewSend({
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  }) async {
    final utxos = await _confirmedUtxos(fromAddress);
    final feePerKb = await _feePerKb();
    final selection = _select(utxos, amountBaseUnits, feePerKb);
    return MultichainSendPreview(
      feeBaseUnits: selection.feeKoinu,
      feeText: formatAmount(selection.feeKoinu),
      context: selection,
    );
  }

  /// Largest-first selection, same strategy as the BTC service.
  _DogeSelection _select(
    List<_DogeUtxo> utxos,
    BigInt amount,
    BigInt feePerKb,
  ) {
    final sorted = [...utxos]..sort((a, b) => b.valueKoinu - a.valueKoinu);
    final picked = <_DogeUtxo>[];
    var total = BigInt.zero;
    BigInt fee(int inputs, int outputs) =>
        (BigInt.from(_estimateSize(inputs, outputs)) * feePerKb +
            BigInt.from(999)) ~/
        BigInt.from(1000);
    for (final utxo in sorted) {
      picked.add(utxo);
      total += BigInt.from(utxo.valueKoinu);
      final feeWithChange = fee(picked.length, 2);
      final feeNoChange = fee(picked.length, 1);
      final change = total - amount - feeWithChange;
      if (change >= _dustKoinu) {
        return _DogeSelection(
          utxos: picked,
          feeKoinu: feeWithChange,
          changeKoinu: change,
        );
      }
      if (total - amount - feeNoChange >= BigInt.zero) {
        // Remainder below dust: fold it into the fee, no change output.
        return _DogeSelection(
          utxos: picked,
          feeKoinu: total - amount,
          changeKoinu: BigInt.zero,
        );
      }
    }
    throw MultichainRpcException(
      'Insufficient confirmed balance for amount + fee',
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
    final selection = preview.context! as _DogeSelection;
    final rawTx = await rust.signDogeTransaction(
      mnemonic: mnemonic,
      utxos: [
        for (final u in selection.utxos)
          rust.ApiBtcUtxo(
            txid: u.txid,
            vout: u.vout,
            valueSats: BigInt.from(u.valueKoinu),
          ),
      ],
      toAddress: toAddress,
      amountKoinu: amountBaseUnits,
      changeKoinu: selection.changeKoinu,
    );
    final result = await rpc.postJson(chain.endpoints, '/txs/push', {
      'tx': rawTx,
    });
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed broadcast response');
    }
    final hash =
        (result['tx'] as Map<String, dynamic>?)?['hash'] as String?;
    if (hash == null) {
      throw MultichainRpcException('Broadcast rejected: $result');
    }
    return hash;
  }
}

class _DogeUtxo {
  const _DogeUtxo({
    required this.txid,
    required this.vout,
    required this.valueKoinu,
  });

  final String txid;
  final int vout;
  final int valueKoinu;
}

class _DogeSelection {
  const _DogeSelection({
    required this.utxos,
    required this.feeKoinu,
    required this.changeKoinu,
  });

  final List<_DogeUtxo> utxos;
  final BigInt feeKoinu;
  final BigInt changeKoinu;
}

// ======================== Cosmos SDK chains ========================

class CosmosService extends MultichainService {
  CosmosService(super.chain, super.rpc, {int? coinType})
    : coinType = coinType ?? chain.cosmosSlip44 ?? 118,
      assert(
        chain.family == MultichainFamily.cosmos && chain.cosmosHrp != null,
      );

  /// SLIP-44 coin type of the HD path this account signs from (the address
  /// format and digest still follow the chain's key style).
  final int coinType;

  // Keplr's legacy default for bank sends is 80k gas; 100k adds headroom
  // without simulation. IBC transfers use Keplr's ibcTransfer default.
  static const _gasLimit = 100000;
  static const _ibcGasLimit = 450000;

  /// Keplr uses destination latest height + 150 as the timeout height.
  static const _ibcTimeoutHeightMargin = 150;

  BigInt _feeFor(int gasLimit) =>
      BigInt.from((gasLimit * chain.cosmosGasPrice!).ceil());

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
      if (coin['denom'] == chain.cosmosDenom) {
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
    final fee = _feeFor(_gasLimit);
    return MultichainSendPreview(
      feeBaseUnits: fee,
      feeText: formatAmount(fee),
      context: base,
    );
  }

  /// Fee preview for an ics-20 transfer over [route] (fee is paid on this
  /// chain in its own denom; timeout data comes from the destination chain).
  Future<MultichainSendPreview> previewIbcSend({
    required String fromAddress,
    required IbcRoute route,
  }) async {
    final account = _baseAccount(
      await rpc.get(
        chain.endpoints,
        '/cosmos/auth/v1beta1/accounts/$fromAddress',
      ),
    );
    final latestBlock = await rpc.get(
      route.to.endpoints,
      '/cosmos/base/tendermint/v1beta1/blocks/latest',
    );
    if (latestBlock is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed destination block response');
    }
    final heightText =
        ((latestBlock['block'] as Map<String, dynamic>?)?['header']
                as Map<String, dynamic>?)?['height']
            as String?;
    if (heightText == null) {
      throw MultichainRpcException('Destination chain height unavailable');
    }
    final fee = _feeFor(_ibcGasLimit);
    return MultichainSendPreview(
      feeBaseUnits: fee,
      feeText: formatAmount(fee),
      context: _CosmosIbcContext(
        account: account,
        timeoutRevisionNumber: route.to.cosmosChainIdVersion,
        timeoutRevisionHeight:
            int.parse(heightText) + _ibcTimeoutHeightMargin,
      ),
    );
  }

  /// Signs and broadcasts an ics-20 transfer prepared by [previewIbcSend].
  Future<String> sendIbc({
    required String mnemonic,
    required String toAddress,
    required BigInt amountBaseUnits,
    required MultichainSendPreview preview,
    required IbcRoute route,
  }) async {
    final context = preview.context! as _CosmosIbcContext;
    final txBase64 = await rust.signCosmosIbcTransfer(
      mnemonic: mnemonic,
      chainId: chain.cosmosChainId!,
      hrp: chain.cosmosHrp!,
      coinType: coinType,
      ethKey: chain.cosmosUsesEthKey,
      pubkeyTypeUrl: chain.cosmosPubkeyTypeUrl,
      accountNumber: context.account.accountNumber,
      sequence: context.account.sequence,
      sourceChannel: route.channelId,
      toAddress: toAddress,
      amount: amountBaseUnits.toString(),
      denom: chain.cosmosDenom!,
      feeAmount: preview.feeBaseUnits.toString(),
      feeDenom: chain.cosmosDenom!,
      gasLimit: BigInt.from(_ibcGasLimit),
      timeoutRevisionNumber: BigInt.from(context.timeoutRevisionNumber),
      timeoutRevisionHeight: BigInt.from(context.timeoutRevisionHeight),
      memo: '',
    );
    return _broadcast(txBase64);
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
      chainId: chain.cosmosChainId!,
      hrp: chain.cosmosHrp!,
      coinType: coinType,
      ethKey: chain.cosmosUsesEthKey,
      pubkeyTypeUrl: chain.cosmosPubkeyTypeUrl,
      accountNumber: account.accountNumber,
      sequence: account.sequence,
      toAddress: toAddress,
      amount: amountBaseUnits.toString(),
      denom: chain.cosmosDenom!,
      feeAmount: preview.feeBaseUnits.toString(),
      feeDenom: chain.cosmosDenom!,
      gasLimit: BigInt.from(_gasLimit),
      memo: '',
    );
    return _broadcast(txBase64);
  }

  Future<String> _broadcast(String txBase64) async {
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

class _CosmosIbcContext {
  const _CosmosIbcContext({
    required this.account,
    required this.timeoutRevisionNumber,
    required this.timeoutRevisionHeight,
  });

  final _CosmosAccount account;
  final int timeoutRevisionNumber;
  final int timeoutRevisionHeight;
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

// ======================== Sui ========================

class SuiService extends MultichainService {
  SuiService(MultichainRpc rpc) : super(MultichainChain.sui, rpc);

  /// Fixed worst-case budget for a transfer PTB (0.01 SUI); unused gas is
  /// refunded on execution.
  static final _gasBudgetMist = BigInt.from(10000000);

  /// Never smash more coins into gas than this per send.
  static const _maxGasCoins = 32;

  @override
  Future<BigInt> fetchBalance(String address) async {
    final result = await rpc.jsonRpc(chain.endpoints, 'suix_getBalance', [
      address,
    ]);
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed balance response');
    }
    return BigInt.parse(result['totalBalance'] as String);
  }

  @override
  Future<MultichainSendPreview> previewSend({
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  }) async {
    final coinsResult = await rpc.jsonRpc(chain.endpoints, 'suix_getCoins', [
      fromAddress,
      '0x2::sui::SUI',
      null,
      50,
    ]);
    if (coinsResult is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed coins response');
    }
    final gasPriceText =
        await rpc.jsonRpc(chain.endpoints, 'suix_getReferenceGasPrice', []);
    final gasPrice = BigInt.parse(gasPriceText as String);

    // Largest-first coin selection: the picked coins are smashed into the
    // gas object and must cover amount + worst-case gas.
    final coins = (coinsResult['data'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .toList()
      ..sort(
        (a, b) => BigInt.parse(
          b['balance'] as String,
        ).compareTo(BigInt.parse(a['balance'] as String)),
      );
    final needed = amountBaseUnits + _gasBudgetMist;
    final picked = <_SuiGasObject>[];
    var total = BigInt.zero;
    for (final coin in coins) {
      if (picked.length >= _maxGasCoins) break;
      picked.add(
        _SuiGasObject(
          objectId: coin['coinObjectId'] as String,
          version: int.parse(coin['version'] as String),
          digest: coin['digest'] as String,
        ),
      );
      total += BigInt.parse(coin['balance'] as String);
      if (total >= needed) break;
    }
    if (total < needed) {
      throw MultichainRpcException(
        'Insufficient balance for amount + gas budget',
      );
    }
    return MultichainSendPreview(
      feeBaseUnits: _gasBudgetMist,
      feeText: '≤ ${formatAmount(_gasBudgetMist)}',
      context: _SuiContext(gasPrice: gasPrice, gasObjects: picked),
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
    final context = preview.context! as _SuiContext;
    final signed = await rust.signSuiTransfer(
      mnemonic: mnemonic,
      recipient: toAddress,
      amountMist: amountBaseUnits,
      gasBudget: _gasBudgetMist,
      gasPrice: context.gasPrice,
      gasObjects: [
        for (final g in context.gasObjects)
          rust.ApiSuiGasObject(
            objectId: g.objectId,
            version: BigInt.from(g.version),
            digest: g.digest,
          ),
      ],
    );
    final result = await rpc.jsonRpc(
      chain.endpoints,
      'sui_executeTransactionBlock',
      [
        signed.txBytesBase64,
        [signed.signatureBase64],
      ],
    );
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed execute response');
    }
    return result['digest'] as String;
  }
}

class _SuiGasObject {
  const _SuiGasObject({
    required this.objectId,
    required this.version,
    required this.digest,
  });

  final String objectId;
  final int version;
  final String digest;
}

class _SuiContext {
  const _SuiContext({required this.gasPrice, required this.gasObjects});

  final BigInt gasPrice;
  final List<_SuiGasObject> gasObjects;
}

// ======================== Aptos ========================

class AptosService extends MultichainService {
  AptosService(MultichainRpc rpc) : super(MultichainChain.aptos, rpc);

  /// Worst-case gas units for `aptos_account::transfer` (covers creating the
  /// recipient account); unused gas is not charged.
  static const _maxGasAmount = 2000;

  /// Transaction expiry window.
  static const _expirySeconds = 600;

  @override
  Future<BigInt> fetchBalance(String address) async {
    try {
      final result = await rpc.get(
        chain.endpoints,
        '/accounts/$address/balance/0x1::aptos_coin::AptosCoin',
      );
      if (result is int) return BigInt.from(result);
      if (result is String) return BigInt.parse(result);
      throw MultichainRpcException('Malformed balance response');
    } on MultichainRpcException catch (e) {
      // A fresh address has no account on chain yet.
      if (e.message.contains('account_not_found')) return BigInt.zero;
      rethrow;
    }
  }

  @override
  Future<MultichainSendPreview> previewSend({
    required String fromAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  }) async {
    final account = await rpc.get(chain.endpoints, '/accounts/$fromAddress');
    if (account is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed account response');
    }
    final gas = await rpc.get(chain.endpoints, '/estimate_gas_price');
    if (gas is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed gas estimate response');
    }
    final info = await rpc.get(chain.endpoints, '');
    if (info is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed node info response');
    }
    final gasUnitPrice = gas['gas_estimate'] as int;
    final worstCaseFee = BigInt.from(gasUnitPrice * _maxGasAmount);
    return MultichainSendPreview(
      feeBaseUnits: worstCaseFee,
      feeText: '≤ ${formatAmount(worstCaseFee)}',
      context: _AptosContext(
        sequenceNumber: BigInt.parse(account['sequence_number'] as String),
        gasUnitPrice: gasUnitPrice,
        chainId: info['chain_id'] as int,
        expirationTimestampSecs:
            DateTime.now().millisecondsSinceEpoch ~/ 1000 + _expirySeconds,
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
    final context = preview.context! as _AptosContext;
    final signed = await rust.signAptosTransfer(
      mnemonic: mnemonic,
      sequenceNumber: context.sequenceNumber,
      toAddress: toAddress,
      amountOctas: amountBaseUnits,
      maxGasAmount: BigInt.from(_maxGasAmount),
      gasUnitPrice: BigInt.from(context.gasUnitPrice),
      expirationTimestampSecs: BigInt.from(context.expirationTimestampSecs),
      chainId: context.chainId,
    );
    // JSON submission: the node rebuilds the BCS signing message from these
    // fields and verifies the signature, so any mismatch with what Rust
    // signed is rejected at the node.
    final result = await rpc.postJson(chain.endpoints, '/transactions', {
      'sender': fromAddress,
      'sequence_number': context.sequenceNumber.toString(),
      'max_gas_amount': '$_maxGasAmount',
      'gas_unit_price': '${context.gasUnitPrice}',
      'expiration_timestamp_secs': '${context.expirationTimestampSecs}',
      'payload': {
        'type': 'entry_function_payload',
        'function': '0x1::aptos_account::transfer',
        'type_arguments': <String>[],
        'arguments': [toAddress, amountBaseUnits.toString()],
      },
      'signature': {
        'type': 'ed25519_signature',
        'public_key': signed.publicKeyHex,
        'signature': signed.signatureHex,
      },
    });
    if (result is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed submit response');
    }
    return result['hash'] as String;
  }
}

class _AptosContext {
  const _AptosContext({
    required this.sequenceNumber,
    required this.gasUnitPrice,
    required this.chainId,
    required this.expirationTimestampSecs,
  });

  final BigInt sequenceNumber;
  final int gasUnitPrice;
  final int chainId;
  final int expirationTimestampSecs;
}

/// Service lookup by chain family and derivation variant.
MultichainService multichainServiceFor(
  MultichainChain chain,
  MultichainRpc rpc, {
  int? cosmosCoinType,
  bool btcLegacy = false,
}) {
  return switch (chain.family) {
    MultichainFamily.utxo => chain == MultichainChain.doge
        ? DogeService(rpc)
        : BtcService(rpc, legacy: btcLegacy),
    MultichainFamily.evm => EthService(chain, rpc),
    MultichainFamily.cosmos =>
      CosmosService(chain, rpc, coinType: cosmosCoinType),
    MultichainFamily.sol => SolService(rpc),
    MultichainFamily.sui => SuiService(rpc),
    MultichainFamily.aptos => AptosService(rpc),
  };
}
