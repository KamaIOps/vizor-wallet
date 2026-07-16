import 'dart:convert';

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

/// Storage key for user-added catalog chains (JSON list of chain names).
const String kMultichainCustomChainsKey = 'zcash_multichain_custom_chains';

/// Storage key for per-chain coin-type selections (JSON map name → int).
const String kMultichainCoinTypesKey = 'zcash_multichain_coin_types';

/// Whether the user opted in to multichain balances.
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

/// Catalog chains the user added on top of the built-in defaults, by stable
/// chain name. Persisted; unknown names (registry removals) are dropped on
/// load.
class MultichainCustomChainsNotifier extends AsyncNotifier<List<String>> {
  static final _store = AppSecureStore.instance;

  @override
  Future<List<String>> build() async {
    final raw = await _store.readPlain(kMultichainCustomChainsKey);
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final name in decoded)
        if (name is String && MultichainChain.byName(name) != null) name,
    ];
  }

  Future<void> add(String name) async {
    if (MultichainChain.byName(name) == null) return;
    final current = state.value ?? const <String>[];
    if (current.contains(name) ||
        MultichainChain.builtIns.any((c) => c.name == name)) {
      return;
    }
    await _persist([...current, name]);
  }

  Future<void> remove(String name) async {
    final current = state.value ?? const <String>[];
    if (!current.contains(name)) return;
    await _persist([
      for (final n in current)
        if (n != name) n,
    ]);
  }

  Future<void> _persist(List<String> names) async {
    await _store.writePlain(kMultichainCustomChainsKey, jsonEncode(names));
    state = AsyncData(names);
  }
}

final multichainCustomChainsProvider =
    AsyncNotifierProvider<MultichainCustomChainsNotifier, List<String>>(
      MultichainCustomChainsNotifier.new,
    );

/// Per-chain derivation coin-type selections (cosmos chains only). Values
/// outside the chain's candidate list are ignored on read.
class MultichainCoinTypesNotifier extends AsyncNotifier<Map<String, int>> {
  static final _store = AppSecureStore.instance;

  @override
  Future<Map<String, int>> build() async {
    final raw = await _store.readPlain(kMultichainCoinTypesKey);
    if (raw == null || raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return const {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is int && MultichainChain.byName(entry.key) != null)
          entry.key: entry.value as int,
    };
  }

  Future<void> select(MultichainChain chain, int coinType) async {
    if (!chain.cosmosCoinTypeCandidates.contains(coinType)) return;
    final next = {...state.value ?? const <String, int>{}};
    if (coinType == chain.cosmosSlip44) {
      next.remove(chain.name);
    } else {
      next[chain.name] = coinType;
    }
    await _store.writePlain(kMultichainCoinTypesKey, jsonEncode(next));
    state = AsyncData(next);
  }
}

final multichainCoinTypesProvider =
    AsyncNotifierProvider<MultichainCoinTypesNotifier, Map<String, int>>(
      MultichainCoinTypesNotifier.new,
    );

/// The selected (default or user-chosen) account ref for a chain.
final multichainSelectedRefProvider =
    Provider.family<MultichainAccountRef, MultichainChain>((ref, chain) {
      if (chain.family != MultichainFamily.cosmos) {
        return multichainRefFor(chain);
      }
      final overrides =
          ref.watch(multichainCoinTypesProvider).value ??
          const <String, int>{};
      final selected = overrides[chain.name];
      return multichainRefFor(
        chain,
        coinType:
            selected != null &&
                chain.cosmosCoinTypeCandidates.contains(selected)
            ? selected
            : null,
      );
    });

/// The chains shown on the multichain screen: built-in defaults plus the
/// user's added catalog chains, in stable order.
final multichainActiveChainsProvider = Provider<List<MultichainChain>>((ref) {
  final custom =
      ref.watch(multichainCustomChainsProvider).value ?? const <String>[];
  return [
    ...MultichainChain.builtIns,
    for (final name in custom)
      if (MultichainChain.byName(name) != null) MultichainChain.byName(name)!,
  ];
});

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

/// Derived addresses for the active software account, covering every active
/// chain's derivation variants (all cosmos coin-type candidates, both BTC
/// derivations) so funded variants can be discovered.
///
/// The mnemonic crosses to Rust once per account switch / chain-set change
/// and is not retained here; only the derived public addresses are cached in
/// provider state.
final multichainAddressesProvider =
    FutureProvider<Map<MultichainAccountRef, String>?>((ref) async {
      if (!ref.watch(multichainAvailableProvider)) return null;
      // Recompute when the active account changes.
      ref.watch(
        accountProvider.select((s) => s.value?.activeAccountUuid),
      );
      final chains = ref.watch(multichainActiveChainsProvider);
      final cosmosRefs = [
        for (final chain in chains)
          if (chain.family == MultichainFamily.cosmos)
            for (final coinType in chain.cosmosCoinTypeCandidates)
              multichainRefFor(chain, coinType: coinType),
      ];
      final mnemonic = await ref
          .read(accountProvider.notifier)
          .getActiveMnemonic();
      if (mnemonic == null) return null;
      final addresses = await rust.getMultichainAddresses(
        mnemonic: mnemonic,
        cosmosSpecs: [
          for (final cosmosRef in cosmosRefs)
            rust.ApiCosmosAddressSpec(
              hrp: cosmosRef.chain.cosmosHrp!,
              coinType: cosmosRef.coinType!,
              ethKey: cosmosRef.chain.cosmosUsesEthKey,
            ),
        ],
      );
      final book = <MultichainAccountRef, String>{};
      for (final chain in chains) {
        switch (chain.family) {
          case MultichainFamily.utxo:
            if (chain == MultichainChain.doge) {
              book[multichainRefFor(chain)] = addresses.doge;
            } else {
              book[multichainRefFor(chain)] = addresses.btc;
              book[multichainRefFor(chain, btcLegacy: true)] =
                  addresses.btcLegacy;
            }
          case MultichainFamily.evm:
            book[multichainRefFor(chain)] = addresses.eth;
          case MultichainFamily.cosmos:
            break; // filled from cosmosRefs below
          case MultichainFamily.sol:
            book[multichainRefFor(chain)] = addresses.sol;
          case MultichainFamily.sui:
            book[multichainRefFor(chain)] = addresses.sui;
          case MultichainFamily.aptos:
            book[multichainRefFor(chain)] = addresses.aptos;
        }
      }
      for (var i = 0; i < cosmosRefs.length; i++) {
        book[cosmosRefs[i]] = addresses.cosmos[i];
      }
      return book;
    });

/// On-demand balance for one account (chain + derivation variant). Never
/// background-polled: this only runs while a widget watching it is mounted
/// (multichain screen open), per the on-demand discipline. Refresh via
/// `ref.invalidate`.
final multichainBalanceProvider =
    FutureProvider.family<BigInt, MultichainAccountRef>((
      ref,
      accountRef,
    ) async {
      final addresses = await ref.watch(multichainAddressesProvider.future);
      final address = addresses?[accountRef];
      if (address == null) {
        throw MultichainRpcException('Multichain unavailable');
      }
      final service = multichainServiceFor(
        accountRef.chain,
        ref.watch(multichainRpcProvider),
        cosmosCoinType: accountRef.coinType,
        btcLegacy: accountRef.btcLegacy,
      );
      return service.fetchBalance(address);
    });

String multichainAddressFor(
  Map<MultichainAccountRef, String> addresses,
  MultichainAccountRef accountRef,
) {
  final address = addresses[accountRef];
  if (address == null) {
    throw MultichainRpcException(
      'Address unavailable for ${accountRef.chain.name}',
    );
  }
  return address;
}
