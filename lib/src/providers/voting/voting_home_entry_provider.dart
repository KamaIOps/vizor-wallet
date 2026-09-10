import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/voting/resolved_voting_config_extensions.dart';
import '../../services/voting/voting_models.dart';
import '../account_provider.dart';
import '../app_security_provider.dart';
import '../rpc_endpoint_provider.dart';
import '../sync_provider.dart';
import 'voting_config_provider.dart';
import 'voting_config_source_provider.dart';
import 'voting_home_cache_provider.dart';
import 'voting_round_visibility_provider.dart';
import 'voting_service_providers.dart';
import 'voting_share_tracking_registry_provider.dart';

/// Only cached data is observed here. In particular, never watch the poll-list,
/// eligibility, session, PIR, or recovery providers from Home.
final votingHomeEntryVisibleProvider = Provider<bool>((ref) {
  ref.watch(votingHomeCacheProvider);
  final account = ref.watch(
    accountProvider.select((s) => s.value?.activeAccountUuid),
  );
  final source = ref.watch(
    votingConfigSourceProvider.select((s) => s.value?.sourceUrl),
  );
  final network = ref.watch(rpcEndpointProvider.select((s) => s.networkName));
  final showTest = ref.watch(showTestVotingRoundsProvider).value ?? false;
  final scanned = ref.watch(
    syncProvider.select((s) => s.value?.scannedHeight ?? 0),
  );
  if (account == null || source == null) return false;
  return ref
      .read(votingHomeCacheProvider.notifier)
      .shouldShow(
        listKey: votingHomeListKey(network, source),
        network: network,
        accountUuid: account,
        showTestRounds: showTest,
        now: ref.read(votingHomeClockProvider)(),
        scannedHeight: scanned,
      );
});

final votingHomeRefreshProvider = Provider((ref) => VotingHomeRefresh(ref));

class VotingHomeRefresh {
  VotingHomeRefresh(this.ref);
  final Ref ref;
  Future<void>? _inFlight;
  // Failed requests do not advance the durable six-hour success timestamp.
  // A short process-local cooldown prevents rebuild/reentry retry storms.
  final Map<String, DateTime> _failures = {};

  Future<void> refresh() =>
      _inFlight ??= _refresh().whenComplete(() => _inFlight = null);

  Future<void> _refresh() async {
    final release = ref
        .read(votingShareTrackingRegistryProvider)
        .beginBackgroundWork();
    if (release == null) return;
    String? key;
    try {
      if (ref.read(appSecurityProvider).requiresUnlock) return;
      final source = (await ref.read(
        votingConfigSourceProvider.future,
      )).sourceUrl;
      final network = ref.read(rpcEndpointProvider).networkName;
      key = votingHomeListKey(network, source);
      final cache = ref.read(votingHomeCacheProvider.notifier);
      await cache.ensureLoaded();
      if (!ref.mounted) return;
      final account = ref.exists(accountProvider)
          ? ref.read(accountProvider).value?.activeAccountUuid
          : null;
      final sync = ref.exists(syncProvider)
          ? ref.read(syncProvider).value?.scopedToAccount(account)
          : null;
      if (account != null && sync != null && sync.hasAccountScopedData) {
        await cache.invalidateEligibilityAfterRewind(
          network: network,
          accountUuid: account,
          scannedHeight: sync.scannedHeight,
        );
      }
      final now = ref.read(votingHomeClockProvider)();
      if (cache.list(key)?.isFresh(now) ?? false) return;
      final failedAt = _failures[key];
      if (failedAt != null &&
          now.difference(failedAt) < const Duration(minutes: 5)) {
        return;
      }

      if (ref.exists(votingConfigProvider) &&
          !ref.read(votingConfigProvider).isLoading) {
        await ref.read(votingConfigProvider.notifier).refresh();
      }
      final config = await ref.read(votingConfigProvider.future);
      // Last-good config on a transport failure is useful to voting flows, but
      // must not count as a successful Home refresh for another six hours.
      if (ref.read(votingConfigRefreshFailureProvider) != null) {
        throw StateError('Voting config refresh failed');
      }
      if (ref.read(votingConfigSourceProvider).value?.sourceUrl != source ||
          ref.read(rpcEndpointProvider).networkName != network) {
        return;
      }
      final rounds = config.authenticatedRounds.isEmpty
          ? <VotingRoundSummary>[]
          : (await ref
                    .read(votingApiClientProvider(config.apiServers))
                    .listRounds())
                .where((round) => config.isRoundAuthenticated(round.roundId))
                .toList(growable: false);
      if (!ref.mounted || ref.read(appSecurityProvider).requiresUnlock) return;
      if (ref.read(votingConfigSourceProvider).value?.sourceUrl != source ||
          ref.read(rpcEndpointProvider).networkName != network ||
          !identical(ref.read(votingConfigProvider).value, config)) {
        return;
      }
      await cache.recordList(
        key,
        VotingHomeRoundList(
          checkedAt: now,
          fingerprint: config.sourceFingerprint,
          rounds: rounds,
        ),
      );
      _failures.remove(key);
    } catch (error) {
      if (key != null && ref.mounted) {
        _failures[key] = ref.read(votingHomeClockProvider)();
      }
      debugPrint('Voting Home discovery failed: $error');
    } finally {
      release();
    }
  }
}

final votingHomeRefreshActionProvider = Provider<Future<void> Function()>((
  ref,
) {
  return ref.watch(votingHomeRefreshProvider).refresh;
});
