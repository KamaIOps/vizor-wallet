import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/voting/voting_poll_ordering.dart';
import '../../rust/api/voting.dart' as rust;
import '../../services/voting/resolved_voting_config_extensions.dart';
import '../../services/voting/voting_http.dart';
import '../../services/voting/voting_participation_client.dart';
import '../account_provider.dart';
import '../app_security_provider.dart';
import '../rpc_endpoint_provider.dart';
import '../sync_provider.dart';
import 'voting_config_provider.dart';
import 'voting_config_source_provider.dart';
import 'voting_home_cache_provider.dart';
import 'voting_home_entry_provider.dart';
import 'voting_service_providers.dart';
import 'voting_round_visibility_provider.dart';
import 'voting_share_tracking_registry_provider.dart';
import 'voting_state.dart';

const votingAlreadyUsedMessage =
    'These funds were already used for this round. Voting cannot be restarted on this device.';

/// Integration tests can supply their signed, local regtest config identity.
/// This changes routing support only, never a participation result.
final votingParticipationSourceSupportedProvider =
    Provider<bool Function(String, String)>(
      (ref) =>
          (network, source) =>
              votingDiscoveryScopeForSource(network, source) != null,
    );

final votingParticipationClientProvider = Provider((ref) {
  final http = DartIoVotingHttpClient();
  ref.onDispose(() => http.close(force: true));
  return VotingParticipationClient(http, const VotingParticipationBridge());
});

final votingParticipationProvider = Provider(
  (ref) => VotingParticipationCoordinator(ref),
);

/// UI reads only account-scoped cached facts. Recovery takes precedence.
final votingParticipationUnavailableProvider = Provider.family<bool, String>((
  ref,
  round,
) {
  ref.watch(votingHomeCacheProvider);
  final account = ref.watch(accountProvider).value?.activeAccountUuid;
  final network = ref.watch(rpcEndpointProvider).networkName;
  final source = ref.watch(votingConfigSourceProvider).value?.sourceUrl;
  final height = ref.watch(syncProvider).value?.scannedHeight ?? 0;
  if (account == null || source == null) return false;
  final cache = ref.read(votingHomeCacheProvider.notifier);
  final list = cache.list(votingHomeListKey(network, source));
  final fingerprint =
      list?.fingerprint ??
      ref.watch(votingConfigProvider).value?.sourceFingerprint;
  if (fingerprint == null) return false;
  final fact = cache.fact(
    votingHomeFactKey(network, fingerprint, account, round),
  );
  return fact.progress != VotingHomeProgress.inProgress &&
      fact.progress != VotingHomeProgress.completed &&
      fact.snapshotHeight != null &&
      height >= fact.snapshotHeight! &&
      (fact.participation?.unavailable ?? false);
});

class VotingParticipationCoordinator {
  VotingParticipationCoordinator(this.ref) {
    ref.listen(
      accountProvider.select((s) => s.value?.activeAccountUuid),
      (_, _) => _epoch++,
    );
    ref.listen(
      rpcEndpointProvider.select((s) => s.networkName),
      (_, _) => _epoch++,
    );
    ref.listen(
      votingConfigSourceProvider.select((s) => s.value?.sourceUrl),
      (_, _) => _epoch++,
    );
    ref.listen(
      appSecurityProvider.select((s) => s.requiresUnlock),
      (_, _) => _epoch++,
    );
    ref.onDispose(() => _epoch++);
  }
  final Ref ref;
  int _epoch = 0;
  Future<void> _tail = Future.value();
  final Map<
    String,
    ({Future<void> future, bool Function() current, bool homeOnly})
  >
  _pending = {};
  // Only retain details while waiting for the local snapshot to sync.
  final Map<String, VotingRoundDetails> _syncWaitingDetails = {};
  // In-memory only: a fresh app session may check immediately.
  final Map<String, ({Duration delay, DateTime retryAt})> _failed = {};

  Future<void> checkHomeCandidates({bool Function()? isHomeCurrent}) async {
    if (isHomeCurrent?.call() == false) return;
    if (ref.read(appSecurityProvider).requiresUnlock) return;
    final source = ref.read(votingConfigSourceProvider).value?.sourceUrl;
    final network = ref.read(rpcEndpointProvider).networkName;
    if (source == null ||
        !ref.read(votingParticipationSourceSupportedProvider)(
          network,
          source,
        )) {
      return;
    }
    final cache = ref.read(votingHomeCacheProvider.notifier);
    // The Home discovery path owns loading this cache; don't add storage work
    // outside the destructive drain here.
    final list = cache.list(votingHomeListKey(network, source));
    if (list == null) return;
    final epoch = _epoch;
    final account = ref.read(accountProvider).value?.activeAccountUuid;
    if (account == null) return;
    final showTest = ref.read(showTestVotingRoundsProvider).value ?? false;
    final scannedHeight = ref.read(syncProvider).value?.scannedHeight ?? 0;
    for (final round in list.rounds) {
      if (epoch != _epoch || isHomeCurrent?.call() == false) return;
      if (!showTest && isHiddenTestVotingRoundTitle(round.title)) continue;
      final fact = cache.fact(
        votingHomeFactKey(network, list.fingerprint, account, round.roundId),
      );
      if ((fact.progress == VotingHomeProgress.inProgress ||
              fact.progress == VotingHomeProgress.completed) ||
          fact.participation != null) {
        continue;
      }
      if (fact.eligibility == VotingHomeEligibility.ineligible &&
          fact.snapshotHeight != null &&
          scannedHeight >= fact.snapshotHeight!) {
        continue;
      }
      if (!ref.mounted || ref.read(appSecurityProvider).requiresUnlock) return;
      if (votingPollListStatus(round.status) != VotingPollListStatus.active) {
        continue;
      }
      final end = votingRoundEndDate(round.rawJson);
      if (end != null && !ref.read(votingHomeClockProvider)().isBefore(end)) {
        continue;
      }
      final snapshot = int.tryParse('${round.rawJson['snapshot_height']}');
      if (snapshot != null && scannedHeight < snapshot) continue;
      votingHomeTrace(
        'participation.home.candidate scanned=$scannedHeight snapshot=$snapshot',
      );
      await checkRound(round.roundId, isHomeCurrent: isHomeCurrent);
    }
  }

  Future<void> checkRound(
    String round, {
    bool force = false,
    VotingRoundDetails? knownRound,
    bool Function()? isHomeCurrent,
  }) {
    final account = ref.read(accountProvider).value?.activeAccountUuid;
    final network = ref.read(rpcEndpointProvider).networkName;
    final source = ref.read(votingConfigSourceProvider).value?.sourceUrl;
    if (account == null ||
        source == null ||
        ref.read(appSecurityProvider).requiresUnlock ||
        !ref.read(votingParticipationSourceSupportedProvider)(
          network,
          source,
        )) {
      return Future.value();
    }
    final requestEpoch = _epoch;
    final key = '$network|$source|$account|$round';
    if (_pending[key] case final pending?) {
      if (pending.current() && !(pending.homeOnly && isHomeCurrent == null)) {
        return pending.future;
      }
      // A detail request or new Home visit must not inherit cancelled Home work.
      return pending.future.then<void>((_) async {
        if (!ref.mounted ||
            requestEpoch != _epoch ||
            isHomeCurrent?.call() == false) {
          return;
        }
        await checkRound(
          round,
          force: force,
          knownRound: knownRound,
          isHomeCurrent: isHomeCurrent,
        );
      });
    }
    final release = ref
        .read(votingShareTrackingRegistryProvider)
        .beginBackgroundWork(accountUuid: account);
    if (release == null) return Future.value();
    final epoch = _epoch;
    bool current() =>
        ref.mounted &&
        epoch == _epoch &&
        isHomeCurrent?.call() != false &&
        !ref.read(appSecurityProvider).requiresUnlock &&
        !ref.read(votingShareTrackingRegistryProvider).isQuiesced(account);
    final operation = _tail
        .then((_) async {
          if (!current()) return;
          final clock = ref.read(votingHomeClockProvider);
          final failed = _failed[key];
          if (!force && failed != null && clock().isBefore(failed.retryAt)) {
            votingHomeTrace(
              'participation.skip.backoff retryAt=${failed.retryAt.toIso8601String()}',
            );
            return;
          }
          final cache = ref.read(votingHomeCacheProvider.notifier);
          await cache.ensureLoaded();
          if (!current()) return;
          final list = cache.list(votingHomeListKey(network, source));
          if (list != null) {
            final fact = cache.fact(
              votingHomeFactKey(network, list.fingerprint, account, round),
            );
            if (!force &&
                (fact.participation != null ||
                    fact.progress == VotingHomeProgress.completed ||
                    fact.progress == VotingHomeProgress.inProgress)) {
              return;
            }
          }
          final config = await ref.read(votingConfigProvider.future);
          if (!current()) return;
          config.assertRoundAuthenticated(round);
          final currentFact = cache.fact(
            votingHomeFactKey(
              network,
              config.sourceFingerprint,
              account,
              round,
            ),
          );
          if (!force &&
              (currentFact.participation != null ||
                  currentFact.progress == VotingHomeProgress.inProgress ||
                  currentFact.progress == VotingHomeProgress.completed)) {
            return;
          }
          final detailsKey =
              '$network|${config.sourceFingerprint}|$account|$round';
          if (force) _syncWaitingDetails.remove(detailsKey);
          final details =
              knownRound ??
              _syncWaitingDetails[detailsKey] ??
              VotingRoundDetails.fromStatus(
                await ref
                    .read(votingApiClientProvider(config.apiServers))
                    .getRoundStatus(round),
              );
          if (!current()) return;
          final dbPath = await ref.read(votingWalletDbPathProvider)();
          final scan = await ref
              .read(votingWalletSyncReadinessCheckerProvider)
              .check(
                dbPath: dbPath,
                network: network,
                snapshotHeight: details.snapshotHeight,
              );
          if (!current()) return;
          if (!scan.isReady) {
            votingHomeTrace(
              'participation.wait-sync snapshot=${details.snapshotHeight}',
            );
            _syncWaitingDetails[detailsKey] = details;
            return;
          }
          _syncWaitingDetails.remove(detailsKey);
          final params = await ref
              .read(votingRustApiProvider)
              .trustedVotingRoundParamsFromConfig(
                config: config,
                roundId: round,
                snapshotHeight: BigInt.from(details.snapshotHeight),
                ncRoot: details.ncRoot,
                nullifierImtRoot: details.nullifierImtRoot,
              );
          if (!current()) return;
          final endpoint = ref.read(votingRpcEndpointConfigProvider);
          final context = rust.ApiVotingRoundContext(
            dbPath: dbPath,
            accountUuid: account,
            network: network,
            lightwalletdUrl: endpoint.normalizedLightwalletdUrl,
            roundParams: params,
            roundName: details.title,
            sessionJson: details.sessionJson,
            maxRealNotesPerBundle: null,
            pirLayout: config.pirLayout,
          );
          votingHomeTrace(
            'participation.check.start home=${isHomeCurrent != null} force=$force snapshot=${details.snapshotHeight}',
          );
          final checkTimer = Stopwatch()..start();
          final result = await ref
              .read(votingParticipationClientProvider)
              .check(context, clock, current);
          votingHomeTrace(
            'participation.check.done elapsedMs=${checkTimer.elapsedMilliseconds} unavailable=${result.unavailable}',
          );
          if (!current() ||
              !identical(ref.read(votingConfigProvider).value, config)) {
            return;
          }
          await cache.recordParticipation(
            votingHomeFactKey(
              network,
              config.sourceFingerprint,
              account,
              round,
            ),
            details.snapshotHeight,
            result,
          );
          _failed.remove(key);
        })
        .catchError((Object _) {
          // Raw RPC errors may contain a queried identifier. Never log them.
          // Lock/account/source changes cancel work; they are not failed checks.
          if (!current()) return;
          final previousMinutes = _failed[key]?.delay.inMinutes ?? 0;
          final delay = Duration(
            minutes: previousMinutes == 0
                ? 1
                : (previousMinutes * 2).clamp(1, 30),
          );
          votingHomeTrace(
            'participation.failed retryMinutes=${delay.inMinutes}',
          );
          _failed[key] = (
            delay: delay,
            retryAt: ref.read(votingHomeClockProvider)().add(delay),
          );
        })
        .whenComplete(() {
          release();
          _pending.remove(key);
        });
    _tail = operation;
    _pending[key] = (
      future: operation,
      current: current,
      homeOnly: isHomeCurrent != null,
    );
    return operation;
  }
}
