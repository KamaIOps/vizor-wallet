import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/rust/api/voting.dart' as rust;
import 'package:zcash_wallet/src/services/voting/voting_participation_client.dart';
import 'fake_voting_http.dart';

class _Context implements rust.ApiVotingRoundContext {
  _Context(this.network);
  @override
  final String network;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bridge extends VotingParticipationBridge {
  int evaluations = 0;
  String? evidence;
  bool reject = false;
  @override
  Future<String> prepare(rust.ApiVotingRoundContext context) async =>
      jsonEncode({
        'keys': ['01', '02'],
        'fingerprint': 'notes',
      });
  @override
  Future<String> evaluate(
    rust.ApiVotingRoundContext context,
    String fingerprint,
    String evidence,
    DateTime now,
  ) async {
    evaluations++;
    this.evidence = evidence;
    if (reject) throw StateError('invalid proof');
    return jsonEncode({
      'fingerprint': fingerprint,
      'usedCount': 2,
      'noteCount': 2,
      'remainingEligible': false,
      'localState': false,
    });
  }
}

void main() {
  final now = DateTime.utc(2026, 9, 10);
  FakeVotingHttpClient http() => FakeVotingHttpClient(
    responses: {
      '/commit': {
        'result': {
          'signed_header': {
            'header': {'height': '101'},
          },
        },
      },
      '/validators': {
        'result': {'validators': []},
      },
      '/abci_query': {
        'result': {'response': {}},
      },
    },
  );
  test(
    'both networks pin proofs to height before signed header and require Rust verification',
    () async {
      for (final net in ['main', 'test']) {
        final transport = http();
        final bridge = _Bridge();
        final result = await VotingParticipationClient(
          transport,
          bridge,
        ).check(_Context(net), () => now, () => true);
        expect(result.unavailable, true);
        expect(transport.requests, hasLength(4));
        expect(
          transport.requests.first.uri.host,
          net == 'main'
              ? 'vote-rpc-primary.valargroup.org'
              : 'stage.vote-rpc-primary.valargroup.org',
        );
        for (final request in transport.requests.skip(2)) {
          expect(request.method, 'GET');
          expect(request.uri.queryParameters['prove'], 'true');
          expect(request.uri.queryParameters['height'], '100');
          expect(request.timeout, const Duration(seconds: 10));
        }
        expect(bridge.evaluations, 1);
        expect((jsonDecode(bridge.evidence!)['queries'] as List), hasLength(2));
      }
    },
  );
  test('invalid proof never yields an unavailable result', () async {
    final bridge = _Bridge()..reject = true;
    await expectLater(
      VotingParticipationClient(
        http(),
        bridge,
      ).check(_Context('main'), () => now, () => true),
      throwsStateError,
    );
  });
  test('cancelled work never reaches transport or evaluation', () async {
    final transport = http();
    final bridge = _Bridge();
    await expectLater(
      VotingParticipationClient(
        transport,
        bridge,
      ).check(_Context('test'), () => now, () => false),
      throwsStateError,
    );
    expect(transport.requests, isEmpty);
    expect(bridge.evaluations, 0);
  });
  test(
    'regtest needs loopback transport and cannot redirect public networks',
    () async {
      final local = http();
      await VotingParticipationClient(
        local,
        _Bridge(),
        regtestEndpoint: Uri.parse('http://127.0.0.1:18080'),
      ).check(_Context('regtest'), () => now, () => true);
      expect(local.requests.every((r) => r.uri.host == '127.0.0.1'), isTrue);
      final public = http();
      await VotingParticipationClient(
        public,
        _Bridge(),
        regtestEndpoint: Uri.parse('http://127.0.0.1:18080'),
      ).check(_Context('main'), () => now, () => true);
      expect(
        public.requests.every(
          (r) => r.uri.host == 'vote-rpc-primary.valargroup.org',
        ),
        isTrue,
      );
      await expectLater(
        VotingParticipationClient(
          http(),
          _Bridge(),
          regtestEndpoint: Uri.parse('http://example.com'),
        ).check(_Context('regtest'), () => now, () => true),
        throwsStateError,
      );
    },
  );
  test('unsupported network never reaches transport', () async {
    final transport = http();
    await expectLater(
      VotingParticipationClient(
        transport,
        _Bridge(),
      ).check(_Context('regtest'), () => now, () => true),
      throwsStateError,
    );
    expect(transport.requests, isEmpty);
  });
}
