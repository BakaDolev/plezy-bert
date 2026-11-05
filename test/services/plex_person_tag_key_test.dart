import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';

import '../test_helpers/backend_client_fixtures.dart';

/// An actor opened from Search arrives with only the server's own person id.
/// The actor page's online sections need the person's plex.tv key, which the
/// server's person record carries (#68).
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });

  tearDown(() async {
    await db.close();
  });

  PlexClient makeClient(Future<http.Response> Function(http.Request request) handler) =>
      testPlexClient(serverId: ServerId('server-id'), handler: handler);

  http.Response json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  test('reads the plex.tv key from the server person record', () async {
    final requests = <Uri>[];
    final client = makeClient((request) async {
      requests.add(request.url);
      if (request.url.path == '/library/people/38943') {
        return json({
          'MediaContainer': {
            'size': 1,
            'Directory': [
              {'id': 38943, 'tag': 'Heath Ledger', 'tagType': 6, 'tagKey': '5d776825eb5d26001f1dd125'},
            ],
          },
        });
      }
      return http.Response('not found', 404);
    });
    addTearDown(client.close);

    expect(await client.fetchPersonTagKey('38943'), '5d776825eb5d26001f1dd125');
    expect(requests.map((uri) => uri.host), isNot(contains('discover.provider.plex.tv')));
  });

  test('a person the server knows no plex.tv key for has none', () async {
    final client = makeClient((request) async {
      if (request.url.path == '/library/people/7') {
        return json({
          'MediaContainer': {
            'size': 1,
            'Directory': [
              {'id': 7, 'tag': 'Local Actor', 'tagType': 6},
            ],
          },
        });
      }
      return http.Response('not found', 404);
    });
    addTearDown(client.close);

    expect(await client.fetchPersonTagKey('7'), isNull);
  });

  test('a failed read has no key and does not throw', () async {
    final client = makeClient((request) async => http.Response('server error', 500));
    addTearDown(client.close);

    expect(await client.fetchPersonTagKey('38943'), isNull);
  });
}
