import 'dart:convert';

import '../../rust/api/voting.dart' as rust;
import 'voting_http.dart';
import 'voting_retry.dart';

/// Consensus/storage verification is performed in Rust. Never log candidate
/// keys, request URLs, evidence, or raw transport exceptions from this client.
class VotingParticipationBridge {
  const VotingParticipationBridge();
  Future<String> prepare(rust.ApiVotingRoundContext context) =>
      rust.prepareVotingParticipation(ctx: context);
  Future<String> evaluate(
    rust.ApiVotingRoundContext context,
    String fingerprint,
    String evidence,
    DateTime now,
  ) => rust.evaluateVotingParticipation(
    ctx: context,
    fingerprint: fingerprint,
    evidence: evidence,
    nowSeconds: now.millisecondsSinceEpoch ~/ 1000,
  );
}

class VotingParticipationResult {
  const VotingParticipationResult({
    required this.fingerprint,
    required this.usedCount,
    required this.noteCount,
    required this.remainingEligible,
    required this.localState,
  });
  final String fingerprint;
  final int usedCount;
  final int noteCount;
  final bool remainingEligible;
  final bool localState;
  bool get unavailable => usedCount > 0 && !remainingEligible && !localState;
  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'usedCount': usedCount,
    'noteCount': noteCount,
    'remainingEligible': remainingEligible,
    'localState': localState,
  };
  factory VotingParticipationResult.fromJson(Map<String, dynamic> j) =>
      VotingParticipationResult(
        fingerprint: j['fingerprint'] as String,
        usedCount: j['usedCount'] as int,
        noteCount: j['noteCount'] as int,
        remainingEligible: j['remainingEligible'] as bool,
        localState: j['localState'] as bool,
      );
}

class VotingParticipationClient {
  VotingParticipationClient(
    this.http,
    this.bridge, {
    this.regtestEndpoint,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;
  final Future<void> Function(Duration) _delay;

  /// Local integration transport; ignored for mainnet and testnet.
  final Uri? regtestEndpoint;
  final VotingHttpClient http;
  final VotingParticipationBridge bridge;
  static const requestTimeout = Duration(seconds: 10);

  Future<VotingParticipationResult> check(
    rust.ApiVotingRoundContext context,
    DateTime Function() clock,
    bool Function() isCurrent,
  ) async {
    final endpoint = switch (context.network) {
      'main' => Uri.parse('https://vote-rpc-primary.valargroup.org'),
      'test' => Uri.parse('https://stage.vote-rpc-primary.valargroup.org'),
      'regtest'
          when regtestEndpoint != null &&
              regtestEndpoint!.scheme == 'http' &&
              const [
                '127.0.0.1',
                'localhost',
                '::1',
              ].contains(regtestEndpoint!.host) =>
        regtestEndpoint!,
      _ => throw StateError('Unsupported voting participation network'),
    };
    final deadline = clock().add(const Duration(minutes: 4));
    void guard() {
      if (!isCurrent() || !clock().isBefore(deadline)) {
        throw StateError('Voting participation check cancelled');
      }
    }

    Future<Map<String, dynamic>> get(
      String path, [
      Map<String, String>? query,
    ]) => withVotingRetry(
      policy: VotingRetryPolicy(
        name: 'participation-read',
        delays: const [Duration(milliseconds: 300)],
        shouldRetry: (error) =>
            error is _TransientParticipationResponse ||
            isRetryableVotingError(error),
      ),
      delay: _delay,
      isCancelled: () => !isCurrent() || !clock().isBefore(deadline),
      operation: () async {
        guard();
        final remaining = deadline.difference(clock());
        final response = await http.get(
          endpoint.replace(path: path, queryParameters: query),
          timeout: remaining < requestTimeout ? remaining : requestTimeout,
        );
        guard();
        if (const [429, 500, 502, 503, 504].contains(response.statusCode)) {
          throw const _TransientParticipationResponse();
        }
        if (response.statusCode != 200 ||
            response.bodyBytes.length > 128 * 1024) {
          throw StateError('Voting participation response unavailable');
        }
        return response.decodeJsonObject();
      },
    );

    Future<VotingParticipationResult> evaluate(
      String fingerprint,
      String evidence,
    ) async {
      guard();
      final result = await bridge.evaluate(
        context,
        fingerprint,
        evidence,
        clock(),
      );
      guard();
      return VotingParticipationResult.fromJson(
        jsonDecode(result) as Map<String, dynamic>,
      );
    }

    guard();
    final candidates =
        jsonDecode(await bridge.prepare(context)) as Map<String, dynamic>;
    guard();
    final keys = (candidates['keys'] as List).cast<String>();
    if (keys.length > 1024) {
      throw StateError('Voting participation note limit exceeded');
    }
    if (keys.isEmpty) {
      // Rust rereads the snapshot and accepts absent evidence only for an
      // unchanged empty note set. Dart does not manufacture a successful result.
      return evaluate(candidates['fingerprint'] as String, '');
    }
    final commit = await get('/commit');
    final header =
        ((commit['result'] as Map)['signed_header'] as Map)['header'] as Map;
    final height = int.parse(header['height'] as String);
    if (height <= 1) throw StateError('Voting chain is not ready');
    final validators = await get('/validators', {
      'height': '$height',
      'per_page': '100',
    });
    final queries = <Map<String, dynamic>>[];
    // Bound concurrent reads and stop between small groups on context changes.
    for (var start = 0; start < keys.length; start += 4) {
      final group = keys.skip(start).take(4);
      queries.addAll(
        await Future.wait(
          group.map(
            (key) => get('/abci_query', {
              'path': '"/store/vote/key"',
              'data': '0x$key',
              'height': '${height - 1}',
              'prove': 'true',
            }),
          ),
        ),
      );
    }
    guard();
    final evidence = jsonEncode({
      'commit': commit,
      'validators': validators,
      'queries': queries,
    });
    return evaluate(candidates['fingerprint'] as String, evidence);
  }
}

// No queried identifiers or response bodies in retryable HTTP errors.
class _TransientParticipationResponse implements Exception {
  const _TransientParticipationResponse();
}
