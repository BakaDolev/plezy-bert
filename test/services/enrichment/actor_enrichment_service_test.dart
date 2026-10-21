import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/services/enrichment/actor_enrichment_client.dart';
import 'package:plezy/services/enrichment/actor_enrichment_service.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../../test_helpers/media_items.dart';

// --- Minimal Wikidata/Wikipedia fixtures for a single successful fetch -----
//
// Only enough shape for ActorEnrichmentClient.fetch to resolve one confident
// candidate: a human (P31=Q5) with an acting occupation (P106=Q33999), an
// acting-flavoured search description, an enwiki sitelink, and a label that
// exactly matches the query name. The full matcher gate is already covered
// by actor_enrichment_client_test.dart; this just needs to produce *a*
// positive ActorInfo so the service's caching behaviour can be exercised.

const _qid = 'Q42';
const _name = 'Jane Doe';
const _bornYear = 1975;
const _bio = 'Jane Doe is an American actress.';
const _enwikiTitle = 'Jane Doe';

Map<String, dynamic> _searchResponse() => {
  'search': [
    {'id': _qid, 'label': _name, 'description': 'American actress'},
  ],
  'success': 1,
};

Map<String, dynamic> _entitiesResponse() => {
  'entities': {
    _qid: {
      'id': _qid,
      'labels': {
        'en': {'language': 'en', 'value': _name},
      },
      'aliases': const {},
      'claims': {
        'P31': [
          {
            'mainsnak': {
              'snaktype': 'value',
              'datavalue': {
                'value': {'id': 'Q5'},
              },
            },
          },
        ],
        'P106': [
          {
            'mainsnak': {
              'snaktype': 'value',
              'datavalue': {
                'value': {'id': 'Q33999'},
              },
            },
          },
        ],
        'P569': [
          {
            'mainsnak': {
              'snaktype': 'value',
              'datavalue': {
                'value': {'time': '+$_bornYear-01-01T00:00:00Z', 'precision': 9},
              },
            },
          },
        ],
      },
      'sitelinks': {
        'enwiki': {'site': 'enwiki', 'title': _enwikiTitle},
      },
    },
    'Q33999': {
      'id': 'Q33999',
      'labels': {
        'en': {'language': 'en', 'value': 'actor'},
      },
    },
  },
  'success': 1,
};

Map<String, dynamic> _occupationLabelsResponse() => {
  'entities': {
    'Q33999': {
      'id': 'Q33999',
      'labels': {
        'en': {'language': 'en', 'value': 'actor'},
      },
    },
  },
  'success': 1,
};

/// A client whose HTTP calls resolve to one confident [ActorInfo] match.
ActorEnrichmentClient _successClient(List<http.Request> captured) {
  final httpClient = MockClient((request) async {
    captured.add(request);
    final action = request.url.queryParameters['action'];

    if (request.url.host == 'www.wikidata.org' && action == 'wbsearchentities') {
      return http.Response(jsonEncode(_searchResponse()), 200, headers: {'content-type': 'application/json'});
    }
    if (request.url.host == 'www.wikidata.org' && action == 'wbgetentities') {
      final isOccupationLabelsCall = request.url.queryParameters['props'] == 'labels';
      final body = isOccupationLabelsCall ? _occupationLabelsResponse() : _entitiesResponse();
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }
    if (request.url.host.endsWith('wikipedia.org')) {
      return http.Response(jsonEncode({'extract': _bio}), 200, headers: {'content-type': 'application/json'});
    }
    return http.Response('unexpected ${request.url}', 500);
  });
  return ActorEnrichmentClient(httpClient: httpClient);
}

/// A client whose HTTP calls always fail — `fetch` swallows the failure and
/// returns `null`, matching the "no confident match" contract.
ActorEnrichmentClient _failingClient(List<http.Request> captured) {
  final httpClient = MockClient((request) async {
    captured.add(request);
    return http.Response('', 500);
  });
  return ActorEnrichmentClient(httpClient: httpClient);
}

/// A client that must never be called (used for offline-path assertions).
/// Records into [captured] before throwing, so an accidental call is
/// observable even though [ActorEnrichmentClient.fetch] swallows the
/// exception and returns `null`.
ActorEnrichmentClient _poisonClient(List<http.Request> captured) {
  final httpClient = MockClient((request) async {
    captured.add(request);
    throw Exception('ActorEnrichmentService must not call the client on this path');
  });
  return ActorEnrichmentClient(httpClient: httpClient);
}

const _expectedPositiveJson = {
  'qid': _qid,
  'bornYear': _bornYear,
  'occupations': ['actor'],
  'bio': _bio,
  'enwikiTitle': _enwikiTitle,
};

void main() {
  late AppDatabase db;
  late PlexApiCache cache;
  const serverId = 'srv1';
  const personId = '99';
  const endpoint = '/enrichment/person/$personId';

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    cache = PlexApiCache.instance;
  });

  tearDown(() async {
    await db.close();
  });

  /// Directly back-dates the row's `cachedAt` so tests can simulate rows
  /// that are stale for the negative TTL but still fresh for the positive
  /// one (or stale for both), without waiting on real time.
  Future<void> ageRow(String key, Duration age) async {
    await (db.update(
      db.apiCache,
    )..where((t) => t.cacheKey.equals(key))).write(ApiCacheCompanion(cachedAt: Value(DateTime.now().subtract(age))));
  }

  final cacheKey = '$serverId:$endpoint';

  group('ActorEnrichmentService.enrichPlex', () {
    test('cache hit positive (<7d) returns ActorInfo without calling the client', () async {
      await cache.put(ServerId(serverId), endpoint, {..._expectedPositiveJson, 'found': true});
      final captured = <http.Request>[];
      final service = ActorEnrichmentService(cache, _poisonClient(captured));

      final info = await service.enrichPlex(serverId: serverId, personId: personId, name: _name);

      expect(info, isNotNull);
      expect(info!.qid, _qid);
      expect(info.bornYear, _bornYear);
      expect(info.occupations, ['actor']);
      expect(info.bio, _bio);
      expect(info.enwikiTitle, _enwikiTitle);
      expect(captured, isEmpty);
    });

    test('cache hit negative (<7d) returns null without calling the client', () async {
      await cache.put(ServerId(serverId), endpoint, {'found': false});
      final captured = <http.Request>[];
      final service = ActorEnrichmentService(cache, _poisonClient(captured));

      final info = await service.enrichPlex(serverId: serverId, personId: personId, name: _name);

      expect(info, isNull);
      expect(captured, isEmpty);
    });

    test('positive row aged 7-90d is still returned on the second read', () async {
      await cache.put(ServerId(serverId), endpoint, {..._expectedPositiveJson, 'found': true});
      await ageRow(cacheKey, const Duration(days: 10));
      final captured = <http.Request>[];
      final service = ActorEnrichmentService(cache, _poisonClient(captured));

      final info = await service.enrichPlex(serverId: serverId, personId: personId, name: _name);

      expect(info, isNotNull);
      expect(info!.qid, _qid);
      expect(captured, isEmpty);
    });

    test('negative row aged 7-90d is treated as a miss and calls the client', () async {
      await cache.put(ServerId(serverId), endpoint, {'found': false});
      await ageRow(cacheKey, const Duration(days: 10));
      final captured = <http.Request>[];
      final service = ActorEnrichmentService(cache, _successClient(captured));

      final info = await service.enrichPlex(serverId: serverId, personId: personId, name: _name);

      expect(info, isNotNull);
      expect(info!.qid, _qid);
      expect(captured, isNotEmpty);
      final row = await cache.get(ServerId(serverId), endpoint);
      expect(row, {..._expectedPositiveJson, 'found': true});
    });

    test('miss calls the client and writes the positive result', () async {
      final captured = <http.Request>[];
      final service = ActorEnrichmentService(cache, _successClient(captured));

      final info = await service.enrichPlex(serverId: serverId, personId: personId, name: _name);

      expect(info, isNotNull);
      expect(info!.qid, _qid);
      expect(captured, isNotEmpty);
      final row = await cache.get(ServerId(serverId), endpoint);
      expect(row, {..._expectedPositiveJson, 'found': true});
    });

    test('miss with a null client result writes {found: false} and returns null', () async {
      final captured = <http.Request>[];
      final service = ActorEnrichmentService(cache, _failingClient(captured));

      final info = await service.enrichPlex(serverId: serverId, personId: personId, name: _name);

      expect(info, isNull);
      expect(captured, isNotEmpty);
      final row = await cache.get(ServerId(serverId), endpoint);
      expect(row, {'found': false});
    });

    test('online:false returns a present row, however stale, without calling the client', () async {
      await cache.put(ServerId(serverId), endpoint, {..._expectedPositiveJson, 'found': true});
      await ageRow(cacheKey, const Duration(days: 200));
      final captured = <http.Request>[];
      final service = ActorEnrichmentService(cache, _poisonClient(captured));

      final info = await service.enrichPlex(serverId: serverId, personId: personId, name: _name, online: false);

      expect(info, isNotNull);
      expect(info!.qid, _qid);
      expect(captured, isEmpty);
    });

    test('online:false with no cached row returns null without calling the client', () async {
      final captured = <http.Request>[];
      final service = ActorEnrichmentService(cache, _poisonClient(captured));

      final info = await service.enrichPlex(serverId: serverId, personId: personId, name: _name, online: false);

      expect(info, isNull);
      expect(captured, isEmpty);
    });
  });

  group('ActorEnrichmentService.enrichJellyfin', () {
    // Pure mapping — no cache/network involved, so every case shares one
    // service built on the poison client: any accidental client/network call
    // fails the test outright.
    ActorEnrichmentService service() {
      final captured = <http.Request>[];
      return ActorEnrichmentService(cache, _poisonClient(captured));
    }

    test('full Person (summary + originallyAvailableAt) maps bio + bornYear, diedYear/occupations empty', () async {
      final person = testMediaItem(
        backend: MediaBackend.jellyfin,
        summary: 'An acclaimed character actor.',
        originallyAvailableAt: '1975-03-14',
      );

      final info = await service().enrichJellyfin(person: person);

      expect(info, isNotNull);
      expect(info!.bio, 'An acclaimed character actor.');
      expect(info.bornYear, 1975);
      expect(info.diedYear, isNull);
      expect(info.occupations, isEmpty);
      expect(info.qid, isNull);
      expect(info.enwikiTitle, isNull);
    });

    test('only summary present maps bio, leaves bornYear null', () async {
      final person = testMediaItem(backend: MediaBackend.jellyfin, summary: 'Known for character roles.');

      final info = await service().enrichJellyfin(person: person);

      expect(info, isNotNull);
      expect(info!.bio, 'Known for character roles.');
      expect(info.bornYear, isNull);
    });

    test('only originallyAvailableAt present maps bornYear, leaves bio null', () async {
      final person = testMediaItem(backend: MediaBackend.jellyfin, originallyAvailableAt: '1968-11-02');

      final info = await service().enrichJellyfin(person: person);

      expect(info, isNotNull);
      expect(info!.bornYear, 1968);
      expect(info.bio, isNull);
    });

    test('empty summary is treated as absent', () async {
      final person = testMediaItem(backend: MediaBackend.jellyfin, summary: '', originallyAvailableAt: '1990-01-01');

      final info = await service().enrichJellyfin(person: person);

      expect(info, isNotNull);
      expect(info!.bio, isNull);
      expect(info.bornYear, 1990);
    });

    test('null person returns null', () async {
      final info = await service().enrichJellyfin(person: null);

      expect(info, isNull);
    });

    test('empty Person (no summary, no date) returns null', () async {
      final person = testMediaItem(backend: MediaBackend.jellyfin);

      final info = await service().enrichJellyfin(person: person);

      expect(info, isNull);
    });
  });
}
