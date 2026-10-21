import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/enrichment/actor_enrichment_client.dart';

// --- Wikidata/Wikipedia fixture builders -----------------------------------

Map<String, dynamic> _searchResponse(List<Map<String, dynamic>> hits) => {
  'searchinfo': {'search': 'query'},
  'search': hits,
  'success': 1,
};

Map<String, dynamic> _searchHit({
  required String id,
  required String label,
  String description = 'American actor',
  List<String>? aliases,
}) => {
  'id': id,
  'label': label,
  'description': description,
  'match': {'type': aliases == null ? 'label' : 'alias', 'language': 'en', 'text': label},
  'aliases': ?aliases,
};

Map<String, dynamic> _valueClaim(String qid) => {
  'mainsnak': {
    'snaktype': 'value',
    'datavalue': {
      'value': {'id': qid},
    },
  },
};

Map<String, dynamic> _timeClaim(int year) => {
  'mainsnak': {
    'snaktype': 'value',
    'datavalue': {
      'value': {'time': '+${year.toString().padLeft(4, '0')}-01-01T00:00:00Z', 'precision': 9},
    },
  },
};

/// A `wbgetentities` entity for a person candidate. [englishDescription],
/// when given, becomes the entity's `descriptions.en.value` — the field the
/// matcher's acting-description gate now reads (i18n fix); omit it to
/// exercise the fallback-to-localized-search-description path instead.
Map<String, dynamic> _personEntity({
  required String qid,
  required String label,
  String locale = 'en',
  bool isHuman = true,
  List<String> occupationQids = const ['Q33999'],
  int? bornYear,
  int? diedYear,
  String? enwikiTitle = 'Jane Doe',
  String? englishDescription,
}) => {
  'id': qid,
  'labels': {
    locale: {'language': locale, 'value': label},
  },
  'aliases': const {},
  'claims': {
    if (isHuman) 'P31': [_valueClaim('Q5')],
    'P106': [for (final q in occupationQids) _valueClaim(q)],
    if (bornYear != null) 'P569': [_timeClaim(bornYear)],
    if (diedYear != null) 'P570': [_timeClaim(diedYear)],
  },
  'sitelinks': {
    if (enwikiTitle != null) 'enwiki': {'site': 'enwiki', 'title': enwikiTitle},
  },
  if (englishDescription != null)
    'descriptions': {
      'en': {'language': 'en', 'value': englishDescription},
    },
};

/// A `wbgetentities` entity for an occupation QID (just needs a label).
Map<String, dynamic> _occupationEntity(String qid, {String locale = 'en', String label = 'actor'}) => {
  'id': qid,
  'labels': {
    locale: {'language': locale, 'value': label},
  },
};

Map<String, dynamic> _entitiesResponse(Map<String, Map<String, dynamic>> entities) => {
  'entities': entities,
  'success': 1,
};

// --- MockClient dispatcher --------------------------------------------------

MockClient _mockClient({
  required List<http.Request> captured,
  Map<String, dynamic>? search,
  int searchStatus = 200,
  bool throwOnSearch = false,
  Map<String, dynamic>? entities,
  int entitiesStatus = 200,
  String? entitiesRawBody,
  // The winner's full-P106 occupation-labels call (Fix 1) is a SEPARATE
  // `wbgetentities` request (`props=labels` only, vs. the main call's
  // `props=labels|aliases|claims|sitelinks`) — distinguished below by that
  // `props` value, exactly like production distinguishes the two calls.
  Map<String, dynamic>? occupationLabels,
  int occupationLabelsStatus = 200,
  bool throwOnOccupationLabels = false,
  Map<String, dynamic>? summary,
  int summaryStatus = 200,
}) {
  return MockClient((request) async {
    captured.add(request);
    final action = request.url.queryParameters['action'];

    if (request.url.host == 'www.wikidata.org' && action == 'wbsearchentities') {
      if (throwOnSearch) throw Exception('network down');
      if (search == null) return http.Response('', searchStatus);
      return http.Response(jsonEncode(search), searchStatus, headers: {'content-type': 'application/json'});
    }

    if (request.url.host == 'www.wikidata.org' && action == 'wbgetentities') {
      final isOccupationLabelsCall = request.url.queryParameters['props'] == 'labels';
      if (isOccupationLabelsCall) {
        if (throwOnOccupationLabels) throw Exception('network down');
        if (occupationLabels == null) return http.Response('', occupationLabelsStatus);
        return http.Response(
          jsonEncode(occupationLabels),
          occupationLabelsStatus,
          headers: {'content-type': 'application/json'},
        );
      }
      if (entitiesRawBody != null) return http.Response(entitiesRawBody, entitiesStatus);
      if (entities == null) return http.Response('', entitiesStatus);
      return http.Response(jsonEncode(entities), entitiesStatus, headers: {'content-type': 'application/json'});
    }

    if (request.url.host.endsWith('wikipedia.org')) {
      if (summary == null) return http.Response('', summaryStatus);
      return http.Response(jsonEncode(summary), summaryStatus, headers: {'content-type': 'application/json'});
    }

    return http.Response('unexpected ${request.url}', 500);
  });
}

void main() {
  group('ActorEnrichmentClient.fetch', () {
    test('clean hit (search -> entities -> summary) returns a populated ActorInfo', () async {
      final captured = <http.Request>[];
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: captured,
          search: _searchResponse([_searchHit(id: 'Q42', label: 'Jane Doe')]),
          entities: _entitiesResponse({
            'Q42': _personEntity(qid: 'Q42', label: 'Jane Doe', bornYear: 1952, enwikiTitle: 'Jane Doe'),
            'Q33999': _occupationEntity('Q33999', label: 'actor'),
          }),
          summary: {'extract': 'Jane Doe is an American actress known for many roles.'},
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      expect(info, isNotNull);
      expect(info!.qid, 'Q42');
      expect(info.bornYear, 1952);
      expect(info.diedYear, isNull); // alive person: no P570 (spec case)
      expect(info.occupations, ['actor']);
      expect(info.bio, 'Jane Doe is an American actress known for many roles.');
      expect(info.enwikiTitle, 'Jane Doe');

      expect(captured, isNotEmpty);
      for (final request in captured) {
        expect(request.headers['user-agent'], ActorEnrichmentClient.userAgent);
      }
    });

    test('deceased actor: P570 present populates diedYear', () async {
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: [],
          search: _searchResponse([_searchHit(id: 'Q7', label: 'John Roe')]),
          entities: _entitiesResponse({
            'Q7': _personEntity(qid: 'Q7', label: 'John Roe', bornYear: 1901, diedYear: 1980, enwikiTitle: 'John Roe'),
            'Q33999': _occupationEntity('Q33999'),
          }),
          summary: {'extract': 'John Roe was an American actor.'},
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'John Roe');

      expect(info, isNotNull);
      expect(info!.bornYear, 1901);
      expect(info.diedYear, 1980);
    });

    test('fuzzy single non-exact-name candidate (passes every other gate) returns null', () async {
      // "Jane Doe Jr." is a fuzzy/prefix match for the query "Jane Doe" that
      // wbsearchentities would happily surface — the controller addendum's
      // exact-name gate must reject it rather than showing the wrong person.
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: [],
          search: _searchResponse([_searchHit(id: 'Q99', label: 'Jane Doe Jr.')]),
          entities: _entitiesResponse({
            'Q99': _personEntity(qid: 'Q99', label: 'Jane Doe Jr.', enwikiTitle: 'Jane Doe Jr.'),
            'Q33999': _occupationEntity('Q33999'),
          }),
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      expect(info, isNull);
    });

    test('two exact-name matches returns null (ambiguous)', () async {
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: [],
          search: _searchResponse([_searchHit(id: 'Q1', label: 'Jane Doe'), _searchHit(id: 'Q2', label: 'Jane Doe')]),
          entities: _entitiesResponse({
            'Q1': _personEntity(qid: 'Q1', label: 'Jane Doe', enwikiTitle: 'Jane Doe'),
            'Q2': _personEntity(qid: 'Q2', label: 'Jane Doe', enwikiTitle: 'Jane Doe (actress)'),
            'Q33999': _occupationEntity('Q33999'),
          }),
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      expect(info, isNull);
    });

    test('empty search results returns null without calling entities', () async {
      final captured = <http.Request>[];
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(captured: captured, search: _searchResponse(const [])),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Nobody Findable');

      expect(info, isNull);
      expect(captured, hasLength(1)); // only the search call was made
    });

    test('HTTP 500 on search returns null', () async {
      final client = ActorEnrichmentClient(httpClient: _mockClient(captured: [], searchStatus: 500));
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      expect(info, isNull);
    });

    test('a thrown exception (e.g. a timeout) is swallowed and returns null', () async {
      final client = ActorEnrichmentClient(httpClient: _mockClient(captured: [], throwOnSearch: true));
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      expect(info, isNull);
    });

    test('malformed entities body (fails decodeJson) returns null', () async {
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: [],
          search: _searchResponse([_searchHit(id: 'Q42', label: 'Jane Doe')]),
          entitiesRawBody: 'not valid json{{{',
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      expect(info, isNull);
    });

    test('empty name returns null without any network call', () async {
      final captured = <http.Request>[];
      final client = ActorEnrichmentClient(httpClient: _mockClient(captured: captured));
      addTearDown(client.dispose);

      final info = await client.fetch(name: '   ');

      expect(info, isNull);
      expect(captured, isEmpty);
    });

    test('alias match accepts a candidate whose label differs from the query name', () async {
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: [],
          search: _searchResponse([
            _searchHit(id: 'Q55', label: 'Jane A. Doe', aliases: ['Jane Doe']),
          ]),
          entities: _entitiesResponse({
            'Q55': _personEntity(qid: 'Q55', label: 'Jane A. Doe', enwikiTitle: 'Jane A. Doe'),
            'Q33999': _occupationEntity('Q33999'),
          }),
          summary: {'extract': 'A bio.'},
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      expect(info, isNotNull);
      expect(info!.qid, 'Q55');
    });

    test('winner with a non-acting occupation resolves the FULL occupations line (Actor, Producer)', () async {
      // Q42 is Actor (P106=Q33999, the acting-gate occupation) AND Producer
      // (P106=Q3282637, a non-acting occupation) — Plex-style "Actor ·
      // Producer" requires both, not just the acting subset.
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: [],
          search: _searchResponse([_searchHit(id: 'Q42', label: 'Jane Doe')]),
          entities: _entitiesResponse({
            'Q42': _personEntity(
              qid: 'Q42',
              label: 'Jane Doe',
              occupationQids: const ['Q33999', 'Q3282637'],
              enwikiTitle: 'Jane Doe',
            ),
            'Q33999': _occupationEntity('Q33999', label: 'actor'),
          }),
          occupationLabels: _entitiesResponse({
            'Q33999': _occupationEntity('Q33999', label: 'actor'),
            'Q3282637': _occupationEntity('Q3282637', label: 'producer'),
          }),
          summary: {'extract': 'Jane Doe is an American actress and producer.'},
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      expect(info, isNotNull);
      // P106 order preserved: actor (Q33999) listed before producer (Q3282637).
      expect(info!.occupations, ['actor', 'producer']);
    });

    test('occupation-labels call fails (thrown exception) falls back to acting-only list', () async {
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: [],
          search: _searchResponse([_searchHit(id: 'Q42', label: 'Jane Doe')]),
          entities: _entitiesResponse({
            'Q42': _personEntity(
              qid: 'Q42',
              label: 'Jane Doe',
              occupationQids: const ['Q33999', 'Q3282637'],
              bornYear: 1952,
              enwikiTitle: 'Jane Doe',
            ),
            'Q33999': _occupationEntity('Q33999', label: 'actor'),
          }),
          throwOnOccupationLabels: true,
          summary: {'extract': 'Jane Doe is an American actress and producer.'},
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe');

      // Fail-soft: the occupation-labels hiccup falls back to the
      // acting-only list — it never nulls the rest of the ActorInfo.
      expect(info, isNotNull);
      expect(info!.qid, 'Q42');
      expect(info.bornYear, 1952);
      expect(info.bio, 'Jane Doe is an American actress and producer.');
      expect(info.occupations, ['actor']);
    });

    test('non-English localeCode still targets en.wikipedia.org for the summary', () async {
      final captured = <http.Request>[];
      final client = ActorEnrichmentClient(
        httpClient: _mockClient(
          captured: captured,
          search: _searchResponse([_searchHit(id: 'Q42', label: 'Jane Doe')]),
          entities: _entitiesResponse({
            'Q42': _personEntity(qid: 'Q42', label: 'Jane Doe', locale: 'fr', enwikiTitle: 'Jane Doe'),
            'Q33999': _occupationEntity('Q33999', locale: 'fr', label: 'actrice'),
          }),
          summary: {'extract': 'A bio.'},
        ),
      );
      addTearDown(client.dispose);

      final info = await client.fetch(name: 'Jane Doe', localeCode: 'fr');

      expect(info, isNotNull);
      final summaryRequests = captured.where((r) => r.url.host.endsWith('wikipedia.org'));
      expect(summaryRequests, hasLength(1));
      expect(summaryRequests.single.url.host, 'en.wikipedia.org');
    });

    test(
      'non-English locale: acting-description gate reads the ENGLISH wbgetentities description, '
      'not the localized wbsearchentities one (i18n fix)',
      () async {
        // The search-result description is French and does NOT contain the
        // gate's English "actor"/"actress" term — pre-fix this candidate
        // would have been rejected (fails closed) for every non-English UI.
        // The entity's `descriptions.en` DOES carry an English acting term,
        // so the fix must accept it.
        final client = ActorEnrichmentClient(
          httpClient: _mockClient(
            captured: [],
            search: _searchResponse([
              _searchHit(id: 'Q42', label: 'Jane Doe', description: 'actrice américaine'),
            ]),
            entities: _entitiesResponse({
              'Q42': _personEntity(
                qid: 'Q42',
                label: 'Jane Doe',
                locale: 'fr',
                enwikiTitle: 'Jane Doe',
                englishDescription: 'American actress',
              ),
              'Q33999': _occupationEntity('Q33999', locale: 'fr', label: 'actrice'),
            }),
            summary: {'extract': 'Une biographie.'},
          ),
        );
        addTearDown(client.dispose);

        final info = await client.fetch(name: 'Jane Doe', localeCode: 'fr');

        expect(info, isNotNull);
        expect(info!.qid, 'Q42');
      },
    );

    test(
      'non-English locale: candidate whose ENGLISH description has no acting term is still rejected '
      'even when the localized search description would (irrelevant existing behavior preserved)',
      () async {
        final client = ActorEnrichmentClient(
          httpClient: _mockClient(
            captured: [],
            search: _searchResponse([
              _searchHit(id: 'Q77', label: 'Jane Doe', description: 'actrice américaine'),
            ]),
            entities: _entitiesResponse({
              'Q77': _personEntity(
                qid: 'Q77',
                label: 'Jane Doe',
                locale: 'fr',
                enwikiTitle: 'Jane Doe',
                englishDescription: 'American politician',
              ),
              'Q33999': _occupationEntity('Q33999', locale: 'fr', label: 'actrice'),
            }),
          ),
        );
        addTearDown(client.dispose);

        final info = await client.fetch(name: 'Jane Doe', localeCode: 'fr');

        expect(info, isNull);
      },
    );
  });
}
