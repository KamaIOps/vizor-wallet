import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_secure_store.dart';
import '../../features/voting/voting_poll_ordering.dart';
import '../../rust/third_party/zcash_voting/wire.dart' as wire;
import '../../services/voting/voting_models.dart';
import 'voting_round_visibility_provider.dart';
import 'voting_share_tracking_registry_provider.dart';

const votingHomeCacheKey = 'zcash_voting_home_cache_v1';
const votingHomeRefreshInterval = Duration(hours: 6);

/// UI hints only. These never authorize a vote or replace live validation.
enum VotingHomeEligibility { unknown, eligible, ineligible }

enum VotingHomeProgress { unknown, available, inProgress, completed }

class VotingHomeRoundList {
  const VotingHomeRoundList({
    required this.checkedAt,
    required this.fingerprint,
    required this.rounds,
    this.discoveryRevision,
    this.discoveryEndpoint,
  });

  final DateTime checkedAt;
  final String fingerprint;
  final List<VotingRoundSummary> rounds;
  final String? discoveryRevision;
  final String? discoveryEndpoint;

  bool isFresh(DateTime now) {
    final age = now.difference(checkedAt);
    return !age.isNegative && age < votingHomeRefreshInterval;
  }

  Map<String, Object?> toJson() => {
    'checkedAt': checkedAt.toIso8601String(),
    'fingerprint': fingerprint,
    if (discoveryRevision != null) 'discoveryRevision': discoveryRevision,
    if (discoveryEndpoint != null) 'discoveryEndpoint': discoveryEndpoint,
    'rounds': [for (final round in rounds) round.rawJson],
  };

  factory VotingHomeRoundList.fromJson(Map<String, dynamic> json) =>
      VotingHomeRoundList(
        checkedAt: DateTime.parse(json['checkedAt'] as String),
        fingerprint: json['fingerprint'] as String,
        discoveryRevision: json['discoveryRevision'] as String?,
        discoveryEndpoint: json['discoveryEndpoint'] as String?,
        rounds: [
          for (final round in json['rounds'] as List)
            VotingRoundSummary.fromJson(
              Map<String, dynamic>.from(round as Map),
            ),
        ],
      );
}

class VotingHomeFact {
  const VotingHomeFact({
    this.eligibility = VotingHomeEligibility.unknown,
    this.progress = VotingHomeProgress.unknown,
    this.snapshotHeight,
  });

  final VotingHomeEligibility eligibility;
  final VotingHomeProgress progress;
  final int? snapshotHeight;

  Map<String, Object?> toJson() => {
    'eligibility': eligibility.name,
    'progress': progress.name,
    'snapshotHeight': snapshotHeight,
  };

  factory VotingHomeFact.fromJson(Map<String, dynamic> json) => VotingHomeFact(
    eligibility: VotingHomeEligibility.values.byName(
      json['eligibility'] as String,
    ),
    progress: VotingHomeProgress.values.byName(json['progress'] as String),
    snapshotHeight: json['snapshotHeight'] as int?,
  );
}

abstract interface class VotingHomeCacheStore {
  Future<String?> read();
  Future<void> write(String value);
}

class _SecureVotingHomeCacheStore implements VotingHomeCacheStore {
  @override
  Future<String?> read() =>
      AppSecureStore.instance.readPlain(votingHomeCacheKey);
  @override
  Future<void> write(String value) =>
      AppSecureStore.instance.writePlain(votingHomeCacheKey, value);
}

final votingHomeCacheStoreProvider = Provider<VotingHomeCacheStore>(
  (ref) => _SecureVotingHomeCacheStore(),
);
final votingHomeClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

String votingHomeListKey(String network, String source) =>
    jsonEncode([network, source]);
String votingHomeFactKey(
  String network,
  String fingerprint,
  String account,
  String round,
) => jsonEncode([network, fingerprint, account, round]);

/// One serialized, durable cache shared by Home and the existing voting flows.
/// Writes register with the account/reset drain before their first await.
class VotingHomeCacheNotifier extends Notifier<int> {
  final Map<String, VotingHomeRoundList> _lists = {};
  final Map<String, VotingHomeFact> _facts = {};
  Future<void>? _load;
  Future<void> _writes = Future.value();

  @override
  int build() => 0;

  VotingHomeRoundList? list(String key) => _lists[key];
  VotingHomeFact fact(String key) => _facts[key] ?? const VotingHomeFact();

  Future<void> ensureLoaded() => _load ??= _read();

  Future<void> _read() async {
    try {
      final raw = await ref.read(votingHomeCacheStoreProvider).read();
      if (!ref.mounted || raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final lists = (json['lists'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(
          key,
          VotingHomeRoundList.fromJson(value as Map<String, dynamic>),
        ),
      );
      final facts = (json['facts'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(
          key,
          VotingHomeFact.fromJson(value as Map<String, dynamic>),
        ),
      );
      _lists.addAll(lists);
      _facts.addAll(facts);
      state++;
    } catch (error) {
      debugPrint('Voting Home cache read failed: $error');
    }
  }

  Future<void> recordList(String key, VotingHomeRoundList list) => _update(() {
    if (_lists[key]?.checkedAt.isAfter(list.checkedAt) ?? false) return false;
    final previous = _lists[key];
    // Existing voting screens also refresh this list. Preserve the last applied
    // hint within the same authenticated source, without inventing a new one.
    _lists[key] =
        list.discoveryRevision == null &&
            previous?.fingerprint == list.fingerprint
        ? VotingHomeRoundList(
            checkedAt: list.checkedAt,
            fingerprint: list.fingerprint,
            rounds: list.rounds,
            discoveryRevision: previous?.discoveryRevision,
            discoveryEndpoint: previous?.discoveryEndpoint,
          )
        : list;
    return true;
  });

  Future<void> recordEligibility(
    String key,
    bool eligible,
    int snapshotHeight,
  ) => _update(() {
    final old = fact(key);
    final nextEligibility = eligible
        ? VotingHomeEligibility.eligible
        : VotingHomeEligibility.ineligible;
    if (old.eligibility == nextEligibility &&
        old.snapshotHeight == snapshotHeight) {
      return false;
    }
    _facts[key] = VotingHomeFact(
      eligibility: eligible
          ? VotingHomeEligibility.eligible
          : VotingHomeEligibility.ineligible,
      progress: old.progress,
      snapshotHeight: snapshotHeight,
    );
    return true;
  });

  Future<void> recordPlan(String key, wire.RoundPlanView? plan) => _update(() {
    final old = fact(key);
    // completedForDisplay may cover only some proposals. Open proposals and
    // blocking recovery must remain discoverable from Home.
    final progress = plan == null
        ? VotingHomeProgress.unknown
        : plan.blockingRecovery
        ? VotingHomeProgress.inProgress
        : plan.completedForDisplay && plan.openProposals.isEmpty
        ? VotingHomeProgress.completed
        : plan.pendingRecovery && !plan.completedForDisplay
        ? VotingHomeProgress.inProgress
        : VotingHomeProgress.available;
    if (old.progress == progress) return false;
    _facts[key] = VotingHomeFact(
      eligibility: old.eligibility,
      progress: progress,
      snapshotHeight: old.snapshotHeight,
    );
    return true;
  });

  Future<void> invalidateEligibilityAfterRewind({
    required String network,
    required String accountUuid,
    required int scannedHeight,
  }) => _update(() {
    var changed = false;
    for (final entry in _facts.entries.toList()) {
      final key = jsonDecode(entry.key) as List;
      final fact = entry.value;
      if (key[0] != network ||
          key[2] != accountUuid ||
          fact.eligibility == VotingHomeEligibility.unknown ||
          fact.snapshotHeight == null ||
          scannedHeight >= fact.snapshotHeight!) {
        continue;
      }
      _facts[entry.key] = VotingHomeFact(progress: fact.progress);
      changed = true;
    }
    return changed;
  });

  Future<void> _update(bool Function() change) async {
    final release = ref
        .read(votingShareTrackingRegistryProvider)
        .beginBackgroundWork();
    if (release == null) return;
    try {
      await ensureLoaded();
      if (!ref.mounted) return;
      if (!change()) return;
      state++;
      await _persist();
    } catch (error) {
      // Discovery hints must never fail an eligibility check or a submission.
      debugPrint('Voting Home cache write failed: $error');
    } finally {
      release();
    }
  }

  Future<void> _persist() {
    final store = ref.read(votingHomeCacheStoreProvider);
    final value = jsonEncode({
      'lists': _lists.map((key, value) => MapEntry(key, value.toJson())),
      'facts': _facts.map((key, value) => MapEntry(key, value.toJson())),
    });
    final write = _writes.then((_) => store.write(value));
    _writes = write.catchError((Object error) {
      debugPrint('Voting Home cache persistence failed: $error');
    });
    return write;
  }

  /// Called by account deletion after the voting drain has completed.
  Future<void> removeAccount(String accountUuid) async {
    await ensureLoaded();
    _facts.removeWhere((key, _) => (jsonDecode(key) as List)[2] == accountUuid);
    state++;
    await _persist();
  }

  /// Called during reset while the drain is held, before secure storage wipe.
  void clearForReset() {
    _lists.clear();
    _facts.clear();
    _load = Future.value();
    state++;
  }

  bool shouldShow({
    required String listKey,
    required String network,
    required String accountUuid,
    required bool showTestRounds,
    required DateTime now,
    required int scannedHeight,
  }) {
    final rounds = list(listKey);
    if (rounds == null) return false;
    return rounds.rounds.any((round) {
      if (!showTestRounds && isHiddenTestVotingRoundTitle(round.title)) {
        return false;
      }
      if (votingPollListStatus(round.status) != VotingPollListStatus.active) {
        return false;
      }
      final end = votingRoundEndDate(round.rawJson);
      if (end != null && !now.isBefore(end)) return false;
      final local = fact(
        votingHomeFactKey(
          network,
          rounds.fingerprint,
          accountUuid,
          round.roundId,
        ),
      );
      if (local.progress == VotingHomeProgress.inProgress) return true;
      if (local.progress == VotingHomeProgress.completed) return false;
      // A rewind below the checked snapshot makes a negative hint uncertain.
      if (local.snapshotHeight != null &&
          scannedHeight < local.snapshotHeight!) {
        return true;
      }
      return local.eligibility != VotingHomeEligibility.ineligible;
    });
  }
}

final votingHomeCacheProvider = NotifierProvider<VotingHomeCacheNotifier, int>(
  VotingHomeCacheNotifier.new,
);

/// Observe an existing check without introducing any Home-side wallet query.
Future<T> observeVotingHomeResult<T>(
  Ref ref, {
  required Future<T> Function() operation,
  required Future<void> Function(VotingHomeCacheNotifier cache, T result)
  record,
}) {
  final release = ref
      .read(votingShareTrackingRegistryProvider)
      .beginBackgroundWork();
  if (release == null) return operation();
  final Future<T> pending;
  try {
    pending = operation();
  } catch (error, stack) {
    release();
    return Future.error(error, stack);
  }
  return pending.then(
    (result) {
      if (!ref.mounted) {
        release();
        return result;
      }
      try {
        // Persistence stays drainable but must not delay session initialization,
        // tracking schedules, or a successful eligibility result.
        unawaited(
          record(ref.read(votingHomeCacheProvider.notifier), result)
              .catchError(
                (Object error) =>
                    debugPrint('Voting Home observation failed: $error'),
              )
              .whenComplete(release),
        );
      } catch (error) {
        release();
        debugPrint('Voting Home observation failed: $error');
      }
      return result;
    },
    onError: (Object error, StackTrace stack) {
      release();
      Error.throwWithStackTrace(error, stack);
    },
  );
}
