import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'support/mobile_voting_regtest_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMobileVotingRegtestRuntime);
  testWidgets(
    'completes a real mobile vote and hides the Home card',
    completeMobileRegtestVote,
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
