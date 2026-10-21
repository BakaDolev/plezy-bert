import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';

/// Covers [PlexClient.fetchItemsByIds] — the batched full-metadata fetch the
/// actor page uses to recover each title's character (Plex's per-person media
/// list carries cast names but not the character they played).
void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
  });

  tearDown(() => database.close());

  test('batches all ids into ONE /library/metadata call and maps each Role character', () async {
    final requestedPaths = <String>[];
    final client = testPlexClient(
      handler: (request) async {
        requestedPaths.add(request.url.path);
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'size': 2,
              'Metadata': [
                {
                  'ratingKey': 'm1',
                  'type': 'movie',
                  'title': 'Movie One',
                  'year': 2010,
                  'Role': [
                    {'tag': 'Jane Doe', 'role': 'Detective Ruiz'},
                    {'tag': 'John Roe', 'role': 'Suspect'},
                  ],
                },
                {
                  'ratingKey': 'm2',
                  'type': 'movie',
                  'title': 'Movie Two',
                  'year': 2012,
                  'Role': [
                    {'tag': 'Jane Doe', 'role': 'Captain Vega'},
                  ],
                },
              ],
            },
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(client.close);

    final items = await client.fetchItemsByIds(['m1', 'm2']);

    // One batched request for both ids — comma-joined path.
    expect(requestedPaths, ['/library/metadata/m1,m2']);
    expect(items, hasLength(2));
    expect(items.firstWhere((i) => i.id == 'm1').roles?.firstWhere((r) => r.tag == 'Jane Doe').role, 'Detective Ruiz');
    expect(items.firstWhere((i) => i.id == 'm2').roles?.firstWhere((r) => r.tag == 'Jane Doe').role, 'Captain Vega');
  });

  test('returns empty and makes no request for empty input', () async {
    var called = false;
    final client = testPlexClient(
      handler: (_) async {
        called = true;
        return http.Response('{}', 200, headers: const {'content-type': 'application/json'});
      },
    );
    addTearDown(client.close);

    final items = await client.fetchItemsByIds(const []);

    expect(items, isEmpty);
    expect(called, isFalse);
  });

  test('a failed batch degrades to an empty result rather than throwing', () async {
    final client = testPlexClient(
      handler: (_) async => http.Response('{}', 503, headers: const {'content-type': 'application/json'}),
    );
    addTearDown(client.close);

    final items = await client.fetchItemsByIds(['m1', 'm2']);

    expect(items, isEmpty);
  });
}
