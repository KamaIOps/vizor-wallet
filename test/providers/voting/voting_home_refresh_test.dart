import 'dart:async';
import 'dart:typed_data';

import 'package:zcash_wallet/src/providers/voting/voting_share_tracking_registry_provider.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';
import 'package:zcash_wallet/src/providers/voting/voting_config_provider.dart';
import 'package:zcash_wallet/src/providers/voting/voting_config_source_provider.dart';
import 'package:zcash_wallet/src/providers/voting/voting_home_cache_provider.dart';
import 'package:zcash_wallet/src/providers/voting/voting_home_entry_provider.dart';
import 'package:zcash_wallet/src/providers/voting/voting_service_providers.dart';
import 'package:zcash_wallet/src/rust/third_party/zcash_voting/config.dart';
import 'package:zcash_wallet/src/services/voting/voting_api_client.dart';
import 'package:zcash_wallet/src/services/voting/voting_models.dart';

import '../../services/voting/fake_voting_http.dart';
import '../../fakes/memory_voting_home_cache_store.dart';

const roundId =
    '0000000000000000000000000000000000000000000000000000000000000001';
VotingRoundSummary round() => VotingRoundSummary.fromJson({
  'vote_round_id': roundId,
  'title': 'Vote',
  'status': '1',
});

class _Security extends AppSecurityNotifier {
  @override
  AppSecurityState build() =>
      const AppSecurityState(isPasswordConfigured: true, isUnlocked: true);
}

class _Source extends VotingConfigSourceNotifier {
  void select(String source) => state = AsyncData(
    VotingConfigSourceState(sourceUrl: source, isDefault: false),
  );
  @override
  Future<VotingConfigSourceState> build() async =>
      const VotingConfigSourceState(sourceUrl: 'source', isDefault: false);
}

class _Config extends VotingConfigNotifier {
  _Config(this.roundIds);
  final List<String> roundIds;
  int loads = 0;
  bool fail = false;
  @override
  Future<ResolvedVotingConfig> build() async {
    loads++;
    return _value;
  }

  @override
  Future<void> refresh() async {
    loads++;
    if (fail) throw StateError('offline');
    state = AsyncData(_value);
  }

  ResolvedVotingConfig get _value => ResolvedVotingConfig(
    sourceFingerprint: 'fingerprint',
    trustedKeyFingerprint: 'keys',
    dynamicConfigFingerprint: 'dynamic',
    voteServers: const [
      ServiceEndpoint(url: 'https://vote.example', label: ''),
    ],
    pirEndpoints: const [],
    pirLayout: const PirLayout(
      pirDepth: 19,
      tier0Layers: 12,
      tier1Layers: 7,
      polyLen: 4096,
    ),
    supportedVersions: const SupportedVersions(
      pir: ['v0'],
      voteProtocol: 'v0',
      tally: 'v0',
      voteServer: 'v1',
    ),
    authenticatedRounds: [
      for (final id in roundIds)
        AuthenticatedRound(roundId: id, eaPk: Uint8List(32)),
    ],
    skippedRoundIds: const [],
    conditions: const [],
  );
}

class _Api extends VotingApiClient {
  _Api()
    : super(
        baseUrl: Uri.parse('https://vote.example'),
        httpClient: FakeVotingHttpClient(responses: {}),
      );
  int calls = 0;
  Completer<void>? gate;
  @override
  Future<List<VotingRoundSummary>> listRounds() async {
    calls++;
    await gate?.future;
    return [round()];
  }
}

void main() {
  late ProviderContainer container;
  late MemoryVotingHomeCacheStore store;
  late _Api api;
  late _Config config;
  late DateTime now;
  void setup(List<String> ids) {
    now = DateTime.utc(2026, 9, 10);
    store = MemoryVotingHomeCacheStore();
    api = _Api();
    config = _Config(ids);
    container = ProviderContainer(
      overrides: [
        appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
        appSecurityProvider.overrideWith(_Security.new),
        votingConfigSourceProvider.overrideWith(_Source.new),
        votingConfigProvider.overrideWith(() => config),
        votingHomeCacheStoreProvider.overrideWithValue(store),
        votingHomeClockProvider.overrideWithValue(() => now),
        votingApiClientProvider.overrideWith((ref, servers) => api),
        // Any accidental Home eligibility or recovery dependency fails the test.
        votingRustApiProvider.overrideWith(
          (_) => throw StateError('Home must not use Rust wallet queries'),
        ),
        votingRecoveryServiceProvider.overrideWith(
          (_) => throw StateError('Home must not load recovery'),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  test(
    'empty authenticated config skips the vote server for six hours',
    () async {
      setup([]);
      final refresh = container.read(votingHomeRefreshProvider);
      await refresh.refresh();
      await refresh.refresh();
      expect(config.loads, 1);
      expect(api.calls, 0);
      now = now.add(const Duration(hours: 6));
      await refresh.refresh();
      expect(config.loads, 2);
      expect(api.calls, 0);
    },
  );

  test(
    'concurrent Home triggers share one list request and honor durable TTL',
    () async {
      setup([roundId]);
      api.gate = Completer<void>();
      final refresh = container.read(votingHomeRefreshProvider);
      final first = refresh.refresh();
      final second = refresh.refresh();
      await Future<void>.delayed(Duration.zero);
      api.gate!.complete();
      await Future.wait([first, second]);
      expect(api.calls, 1);
      expect(config.loads, 1);
      // Recreate the coordinator and cache, as happens on process restart.
      container.invalidate(votingHomeRefreshProvider);
      container.invalidate(votingHomeCacheProvider);
      await container.read(votingHomeRefreshProvider).refresh();
      expect(api.calls, 1);
      expect(config.loads, 1);
      now = now.add(const Duration(hours: 6));
      await container.read(votingHomeRefreshProvider).refresh();
      expect(api.calls, 2);
      expect(config.loads, 2);
    },
  );

  test(
    'source change during list fetch cannot stamp either source fresh',
    () async {
      setup([roundId]);
      api.gate = Completer<void>();
      final loading = container.read(votingHomeRefreshProvider).refresh();
      while (api.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      (container.read(votingConfigSourceProvider.notifier) as _Source).select(
        'other-source',
      );
      api.gate!.complete();
      await loading;
      final cache = container.read(votingHomeCacheProvider.notifier);
      expect(cache.list(votingHomeListKey('main', 'source')), null);
      expect(cache.list(votingHomeListKey('main', 'other-source')), null);
      await container.read(votingHomeRefreshProvider).refresh();
      expect(api.calls, 2);
    },
  );

  test(
    'reset drains in-flight discovery and prevents its cache write',
    () async {
      setup([roundId]);
      api.gate = Completer<void>();
      final loading = container.read(votingHomeRefreshProvider).refresh();
      while (api.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final registry = container.read(votingShareTrackingRegistryProvider);
      var drained = false;
      final draining = registry.quiesceAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, false);
      api.gate!.complete();
      await loading;
      await draining;
      expect(store.value, null);
      registry.resume();
    },
  );

  test(
    'failure preserves the last snapshot without extending success TTL',
    () async {
      setup([roundId]);
      final refresh = container.read(votingHomeRefreshProvider);
      await refresh.refresh();
      final stored = store.value;
      now = now.add(const Duration(hours: 6));
      config.fail = true;
      await refresh.refresh();
      await refresh.refresh();
      expect(config.loads, 2);
      expect(store.value, stored);
      now = now.add(const Duration(minutes: 5));
      config.fail = false;
      await refresh.refresh();
      expect(config.loads, 3);
      expect(api.calls, 2);
    },
  );
}
