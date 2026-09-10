import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/storage/app_secure_store.dart';

const votingConfigSourceKey = 'zcash_voting_config_source_url';
const votingConfigSavedSourcesKey = 'zcash_voting_config_saved_sources';
const votingShowTestRoundsStorageKey = 'vizor_voting_show_test_rounds';

const votingHomeCacheKey = 'zcash_voting_home_cache_v1';

/// Local-only startup data. Never resolves config or reads the wallet DB.
class VotingHomeStartup {
  const VotingHomeStartup({
    this.cacheJson,
    this.sourceUrl,
    this.savedSourcesJson,
    this.showTestRounds = false,
  });
  final String? cacheJson;
  final String? sourceUrl;
  final String? savedSourcesJson;
  final bool showTestRounds;
}

final votingHomeStartupProvider = Provider<VotingHomeStartup?>((_) => null);

Future<VotingHomeStartup?> loadVotingHomeStartup(AppSecureStore storage) async {
  try {
    final values = await Future.wait([
      storage.readPlain(votingHomeCacheKey),
      storage.readPlain(votingConfigSourceKey),
      storage.readPlain(votingConfigSavedSourcesKey),
    ]);
    final prefs = await SharedPreferences.getInstance();
    return VotingHomeStartup(
      cacheJson: values[0],
      sourceUrl: values[1],
      savedSourcesJson: values[2],
      showTestRounds: prefs.getBool(votingShowTestRoundsStorageKey) ?? false,
    );
  } catch (_) {
    // A UI hint must not block wallet startup. Home can retry the local read.
    return null;
  }
}
