import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_secure_store.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../rust/api/chains.dart' as rust;
import '../domain/multichain_chain.dart';
import '../services/multichain_rpc.dart';
import '../services/multichain_services.dart';

/// Storage key for the multichain opt-in (chosen at wallet create/import,
/// changeable later). Default: disabled.
const String kMultichainEnabledKey = 'zcash_multichain_enabled';

/// Whether the user opted in to multichain balances (BTC/ETH/ATOM/SOL).
class MultichainEnabledNotifier extends AsyncNotifier<bool> {
  static final _store = AppSecureStore.instance;

  @override
  Future<bool> build() async {
    return await _store.readPlain(kMultichainEnabledKey) == 'true';
  }

  Future<void> setEnabled(bool enabled) async {
    await _store.writePlain(kMultichainEnabledKey, enabled ? 'true' : 'false');
    state = AsyncData(enabled);
  }
}

final multichainEnabledProvider =
    AsyncNotifierProvider<MultichainEnabledNotifier, bool>(
      MultichainEnabledNotifier.new,
    );

/// True when the multichain UI should be reachable: feature enabled, wallet
/// unlocked, and the active account is a software account (hardware accounts
/// have no seed on this device to derive other chains from).
final multichainAvailableProvider = Provider<bool>((ref) {
  final enabled = ref.watch(multichainEnabledProvider).value ?? false;
  if (!enabled) return false;
  final security = ref.watch(appSecurityProvider);
  if (security.requiresUnlock) return false;
  final accounts = ref.watch(accountProvider).value;
  final active = accounts?.activeAccountUuid;
  if (active == null) return false;
  return !ref.read(accountProvider.notifier).isHardwareAccount(active);
});

/// Shared HTTP client for the multichain public endpoints.
final multichainRpcProvider = Provider<MultichainRpc>((ref) {
  final rpc = MultichainRpc();
  ref.onDispose(rpc.close);
  return rpc;
});

/// Derived per-chain addresses for the active software account.
///
/// The mnemonic crosses to Rust once per account switch and is not retained
/// here; only the derived public addresses are cached in provider state.
final multichainAddressesProvider = FutureProvider<rust.MultichainAddresses?>((
  ref,
) async {
  if (!ref.watch(multichainAvailableProvider)) return null;
  // Recompute when the active account changes.
  ref.watch(
    accountProvider.select((s) => s.value?.activeAccountUuid),
  );
  final mnemonic = await ref.read(accountProvider.notifier).getActiveMnemonic();
  if (mnemonic == null) return null;
  return rust.getMultichainAddresses(mnemonic: mnemonic);
});

/// On-demand balance for one chain. Never background-polled: this only runs
/// while a widget watching it is mounted (multichain screen open), per the
/// on-demand discipline. Refresh via `ref.invalidate`.
final multichainBalanceProvider =
    FutureProvider.family<BigInt, MultichainChain>((ref, chain) async {
      final addresses = await ref.watch(multichainAddressesProvider.future);
      if (addresses == null) {
        throw MultichainRpcException('Multichain unavailable');
      }
      final service = multichainServiceFor(
        chain,
        ref.watch(multichainRpcProvider),
      );
      return service.fetchBalance(_addressFor(addresses, chain));
    });

String multichainAddressFor(
  rust.MultichainAddresses addresses,
  MultichainChain chain,
) => _addressFor(addresses, chain);

String _addressFor(rust.MultichainAddresses addresses, MultichainChain chain) {
  return switch (chain) {
    MultichainChain.btc => addresses.btc,
    MultichainChain.eth => addresses.eth,
    MultichainChain.cosmos => addresses.cosmos,
    MultichainChain.sol => addresses.sol,
  };
}
