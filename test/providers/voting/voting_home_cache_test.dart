import 'dart:async';
import '../../fakes/memory_voting_home_cache_store.dart';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/providers/voting/voting_home_cache_provider.dart';
import 'package:zcash_wallet/src/providers/voting/voting_share_tracking_registry_provider.dart';
import 'package:zcash_wallet/src/services/voting/voting_models.dart';

import '../../features/voting/round_plan_test_utils.dart';

const roundId =
    '0000000000000000000000000000000000000000000000000000000000000001';
const secondRoundId =
    '0000000000000000000000000000000000000000000000000000000000000002';
final now = DateTime.utc(2026, 9, 10);
final listKey = votingHomeListKey('main', 'source');
final factKey = votingHomeFactKey('main', 'fingerprint', 'account-a', roundId);

VotingRoundSummary round({
  String id = roundId,
  String title = 'Vote',
  String status = '1',
  DateTime? end,
}) => VotingRoundSummary.fromJson({
  'vote_round_id': id,
  'title': title,
  'status': status,
  if (end != null) 'vote_end_time': end.toIso8601String(),
});

void main() {
  late ProviderContainer container;
  late MemoryVotingHomeCacheStore store;
  late VotingHomeCacheNotifier cache;
  setUp(() {
    store = MemoryVotingHomeCacheStore();
    container = ProviderContainer(
      overrides: [votingHomeCacheStoreProvider.overrideWithValue(store)],
    );
    cache = container.read(votingHomeCacheProvider.notifier);
  });
  tearDown(() => container.dispose());

  Future<void> seed(List<VotingRoundSummary> rounds) => cache.recordList(
    listKey,
    VotingHomeRoundList(
      checkedAt: now,
      fingerprint: 'fingerprint',
      rounds: rounds,
    ),
  );
  bool visible({
    String account = 'account-a',
    bool showTest = false,
    int scanned = 1000,
  }) => cache.shouldShow(
    listKey: listKey,
    network: 'main',
    accountUuid: account,
    showTestRounds: showTest,
    now: now,
    scannedHeight: scanned,
  );

  test(
    'unknown round is discoverable; empty, test-only and closed lists hide',
    () async {
      expect(visible(), false);
      await seed([round()]);
      expect(visible(), true);
      await seed([]);
      expect(visible(), false);
      await seed([round(title: '[TEST] Vote')]);
      expect(visible(), false);
      expect(visible(showTest: true), true);
      await seed([round(status: '3')]);
      expect(visible(), false);
      await seed([round(end: now)]);
      expect(visible(), false);
    },
  );

  test(
    'negative eligibility is scoped to account and snapshot readiness',
    () async {
      await seed([round()]);
      await cache.recordEligibility(factKey, false, 500);
      expect(visible(), false);
      expect(visible(account: 'account-b'), true);
      expect(visible(scanned: 499), true);
      await cache.recordEligibility(factKey, true, 500);
      expect(visible(), true);
    },
  );

  test(
    'a rewind permanently invalidates eligibility until voting checks again',
    () async {
      await seed([round()]);
      await cache.recordEligibility(factKey, false, 500);
      await cache.invalidateEligibilityAfterRewind(
        network: 'main',
        accountUuid: 'account-a',
        scannedHeight: 499,
      );
      expect(visible(scanned: 1000), true);
      container.dispose();
      container = ProviderContainer(
        overrides: [votingHomeCacheStoreProvider.overrideWithValue(store)],
      );
      cache = container.read(votingHomeCacheProvider.notifier);
      await cache.ensureLoaded();
      expect(visible(scanned: 1000), true);
      await cache.recordEligibility(factKey, false, 500);
      expect(visible(), false);
    },
  );

  test('one unknown round keeps the entry visible', () async {
    await seed([round(), round(id: secondRoundId)]);
    await cache.recordEligibility(factKey, false, 500);
    expect(visible(), true);
  });

  test(
    'completion hides but partial votes and blocking recovery stay visible',
    () async {
      await seed([round()]);
      await cache.recordPlan(
        factKey,
        apiRoundPlan(
          roundId: roundId,
          pendingRecovery: false,
          nextSteps: [],
          openProposals: Uint32List(0),
          allDecided: true,
          completedForDisplay: true,
        ),
      );
      expect(visible(), false);
      await cache.recordPlan(
        factKey,
        apiRoundPlan(
          roundId: roundId,
          pendingRecovery: false,
          nextSteps: [],
          openProposals: Uint32List.fromList([2]),
          allDecided: false,
          completedForDisplay: true,
        ),
      );
      expect(visible(), true);
      await cache.recordEligibility(factKey, false, 500);
      await cache.recordPlan(
        factKey,
        apiRoundPlan(
          roundId: roundId,
          pendingRecovery: true,
          blockingRecovery: true,
          nextSteps: [],
          openProposals: Uint32List(0),
          allDecided: true,
        ),
      );
      expect(visible(), true);
    },
  );

  test('six-hour successful snapshot and facts survive restart', () async {
    await seed([round()]);
    await cache.recordEligibility(factKey, false, 500);
    container.dispose();
    container = ProviderContainer(
      overrides: [votingHomeCacheStoreProvider.overrideWithValue(store)],
    );
    cache = container.read(votingHomeCacheProvider.notifier);
    await cache.ensureLoaded();
    expect(visible(), false);
    expect(
      cache
          .list(listKey)!
          .isFresh(now.add(const Duration(hours: 5, minutes: 59))),
      true,
    );
    expect(
      cache.list(listKey)!.isFresh(now.add(const Duration(hours: 6))),
      false,
    );
    expect(
      cache.list(listKey)!.isFresh(now.subtract(const Duration(seconds: 1))),
      false,
    );
  });

  test('deletion waits for a write and clears only that account', () async {
    await seed([round()]);
    final registry = container.read(votingShareTrackingRegistryProvider);
    store.writeGate = Completer<void>();
    final writing = cache.recordEligibility(factKey, false, 500);
    await Future<void>.delayed(Duration.zero);
    var drained = false;
    final draining = registry.quiesceAndDrain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, false);
    store.writeGate!.complete();
    await writing;
    await draining;
    await cache.removeAccount('account-a');
    expect(visible(), true);
    registry.resume();
  });

  test('reset clears memory and quiescence prevents late writes', () async {
    await seed([round()]);
    final registry = container.read(votingShareTrackingRegistryProvider);
    await registry.quiesceAndDrain();
    cache.clearForReset();
    await cache.recordEligibility(factKey, false, 500);
    expect(cache.list(listKey), null);
    expect(cache.fact(factKey).eligibility, VotingHomeEligibility.unknown);
    registry.resume();
  });

  test('synchronous operation failure releases its discovery lease', () async {
    final action = Provider(
      (ref) =>
          () => observeVotingHomeResult<int>(
            ref,
            operation: () => throw StateError('query failed'),
            record: (_, _) async {},
          ),
    );
    await expectLater(container.read(action)(), throwsStateError);
    final registry = container.read(votingShareTrackingRegistryProvider);
    await registry.quiesceAndDrain().timeout(const Duration(seconds: 1));
    registry.resume();
  });

  test(
    'synchronous recording failure preserves result and releases lease',
    () async {
      final action = Provider(
        (ref) =>
            () => observeVotingHomeResult<int>(
              ref,
              operation: () async => 7,
              record: (_, _) => throw StateError('cache failed'),
            ),
      );
      expect(await container.read(action)(), 7);
      final registry = container.read(votingShareTrackingRegistryProvider);
      await registry.quiesceAndDrain().timeout(const Duration(seconds: 1));
      registry.resume();
    },
  );

  test('corrupt cache is treated as unverified', () async {
    store.value = '{broken';
    await cache.ensureLoaded();
    expect(visible(), false);
    await seed([round()]);
    expect(visible(), true);
  });
}
