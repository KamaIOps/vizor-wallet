import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/services/voting/voting_file_cache.dart';

void main() {
  late Directory root;
  late VotingFileCache cache;
  final key = '0100${'a' * 128}';
  final other = '0100${'b' * 128}';
  final scope = jsonEncode(['main', 'round', '100', 'governance-v1']);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('voting-note-cache-');
    cache = VotingFileCache(directory: () async => root);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'restart preserves used and unused and isolates accounts and rounds',
    () async {
      await cache.writeNotes('a', scope, {
        key: {'used': true, 'height': 10},
        other: {'used': false, 'height': 10},
      });
      final reopened = VotingFileCache(directory: () async => root);
      expect(await reopened.readNotes('a', scope), hasLength(2));
      expect(await reopened.readNotes('b', scope), isEmpty);
      expect(
        await reopened.readNotes(
          'a',
          jsonEncode(['test', 'round', '100', 'governance-v1']),
        ),
        isEmpty,
      );
    },
  );

  test(
    'concurrent stale observations never revert a locally confirmed note',
    () async {
      await Future.wait([
        cache.writeNotes('a', scope, {
          key: {'used': true, 'height': 0},
        }),
        VotingFileCache(directory: () async => root).writeNotes('a', scope, {
          key: {'used': false, 'height': 99},
          other: {'used': false, 'height': 99},
        }),
      ]);
      expect((await cache.readNotes('a', scope))[key]['used'], true);
      expect(await cache.readNotes('a', scope), hasLength(2));
    },
  );

  test('malformed entries are unknown without losing valid siblings', () async {
    await cache.write(
      cache.notePath('a', scope),
      jsonEncode({
        'version': 1,
        'scope': scope,
        'notes': {
          key: {'used': false, 'height': 10},
          other: {'used': 'false', 'height': 10},
          'not-a-key': {'used': true, 'height': 10},
        },
      }),
    );
    expect((await cache.readNotes('a', scope)).keys, [key]);
  });

  test(
    'ended round cleanup prevents late writes but retains other scopes',
    () async {
      final next = jsonEncode(['main', 'next', '100', 'governance-v1']);
      for (final account in ['a', 'b']) {
        await cache.writeNotes(account, scope, {
          key: {'used': true, 'height': 1},
        });
        await cache.writeNotes(account, next, {
          key: {'used': false, 'height': 1},
        });
      }
      await cache.removeRound('main', 'round');
      await cache.writeNotes('a', scope, {
        key: {'used': false, 'height': 2},
      });
      expect(await cache.readNotes('a', scope), isEmpty);
      expect(await cache.readNotes('b', scope), isEmpty);
      expect(await cache.readNotes('b', next), hasLength(1));
      await cache.removeAccount('a');
      expect(await cache.readNotes('a', next), isEmpty);
      expect(await cache.readNotes('b', next), hasLength(1));
      await cache.clear();
      expect(await root.exists(), false);
    },
  );

  test(
    'snapshot registration preserves tokens across client instances',
    () async {
      expect(await cache.snapshotRevision(100), '0');
      await File('${root.path}/snapshots/100').writeAsString('scan-generation');
      final reopened = VotingFileCache(directory: () async => root);
      expect(await reopened.snapshotRevision(100), 'scan-generation');
      expect(await reopened.snapshotRevision(200), '0');
    },
  );
}
