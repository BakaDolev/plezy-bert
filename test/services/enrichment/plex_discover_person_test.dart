import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/plex_discover_client.dart';

import '../../test_helpers/http_fixtures.dart';

const _session = PlexDiscoverSession(accessToken: 'profile-token', clientIdentifier: 'client-id');
const _key = 'PKEY';

final _profile = {
  'MediaContainer': {
    'Metadata': [
      {
        'title': 'Simon Baker',
        'summary': 'An Australian actor and director.',
        'bornAt': '1969-07-30',
        'birthPlace': 'Launceston, Tasmania, Australia',
        'thumb': 'https://static/portrait.jpg',
        'External': [
          {'source': 'instagram', 'url': 'https://instagram.com/x'},
        ],
        'CreditType': [
          {'type': 'actor', 'count': 597, 'title': 'Actor'},
          {'type': 'producer', 'count': 68, 'title': 'Producer'},
        ],
      },
    ],
  },
};

final _credits = {
  'MediaContainer': {
    'CreditGroup': [
      {
        'title': 'Actor',
        'type': 'actor',
        'Credit': [
          {
            'order': 4,
            'role': 'Benton Wesley',
            'Metadata': {'ratingKey': 'a2', 'title': 'Scarpetta', 'type': 'show', 'year': 2026},
          },
        ],
      },
    ],
  },
};

final _knownFor = {
  'MediaContainer': {
    'Metadata': [
      {'ratingKey': 'k1', 'title': 'The Mentalist', 'type': 'show', 'year': 2008, 'parentTitle': 'Patrick Jane'},
    ],
  },
};

PlexDiscoverClient _client(http.Response Function(String path) handler) =>
    PlexDiscoverClient(_session, httpClient: MockClient((request) async => handler(request.url.path)));

void main() {
  group('PlexDiscoverClient.fetchPersonPage', () {
    test('combines profile, credits and known-for into one page', () async {
      final client = _client((path) {
        if (path == '/library/people/$_key') return jsonResponse(_profile);
        if (path == '/library/people/$_key/credits') return jsonResponse(_credits);
        if (path == '/library/people/$_key/person_known_for') return jsonResponse(_knownFor);
        return http.Response('{}', 404);
      });
      addTearDown(client.dispose);

      final page = (await client.fetchPersonPage(_key))!;

      expect(page.bio, 'An Australian actor and director.');
      expect(page.bornYear, 1969);
      expect(page.birthPlace, 'Launceston, Tasmania, Australia');
      expect(page.instagramUrl, 'https://instagram.com/x');
      expect(page.occupations, ['Actor', 'Producer']);
      expect(page.creditGroups.single.label, 'Actor');
      expect(page.creditGroups.single.credits.single.character, 'Benton Wesley');
      expect(page.knownFor.single.title, 'The Mentalist');
      expect(page.knownFor.single.character, 'Patrick Jane');
    });

    test('is best-effort: a failing sub-request drops only that section', () async {
      final client = _client((path) {
        if (path == '/library/people/$_key') return jsonResponse(_profile);
        if (path == '/library/people/$_key/credits') return http.Response('boom', 500);
        if (path == '/library/people/$_key/person_known_for') return jsonResponse(_knownFor);
        return http.Response('{}', 404);
      });
      addTearDown(client.dispose);

      final page = (await client.fetchPersonPage(_key))!;

      expect(page.bio, isNotNull, reason: 'profile still loaded');
      expect(page.knownFor, hasLength(1), reason: 'known-for still loaded');
      expect(page.creditGroups, isEmpty, reason: 'only the failed credits section is dropped');
    });

    test('returns null when nothing renderable comes back', () async {
      final client = _client((_) => http.Response('{}', 404));
      addTearDown(client.dispose);

      expect(await client.fetchPersonPage(_key), isNull);
    });
  });
}
