import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_role.dart';
import 'package:plezy/screens/actor_character_resolver.dart';
import 'package:plezy/screens/actor_filmography.dart';
import 'package:plezy/services/enrichment/person_online_page.dart';

import '../test_helpers/media_items.dart';

const _actorName = 'Jane Doe';

void main() {
  group('mergeCastCrew', () {
    test('folds the detailed cast/crew onto the base item by id, keeping base fields', () {
      // Models the Plex person-media reality: the cast tag is present but the
      // character (role) is null — the batched full-metadata fetch carries it.
      final base = testMediaItem(
        id: 'm1',
        year: 2010,
        title: 'Base Title',
        roles: const [MediaRole(id: 'per-title-credit', tag: _actorName)],
      );
      final detailed = testMediaItem(
        id: 'm1',
        roles: const [MediaRole(id: 'full-credit', tag: _actorName, role: 'Detective Ruiz')],
        directors: const ['Some Director'],
      );

      final merged = mergeCastCrew([base], [detailed]);

      expect(merged, hasLength(1));
      expect(merged.single.id, 'm1');
      expect(merged.single.year, 2010, reason: 'base fields are preserved');
      expect(merged.single.title, 'Base Title');
      expect(merged.single.roles!.single.role, 'Detective Ruiz', reason: 'character now present');
      expect(merged.single.directors, ['Some Director']);
    });

    test('an item with no detailed match keeps its original fields', () {
      final base = testMediaItem(
        id: 'm2',
        year: 2011,
        roles: const [MediaRole(id: 'c', tag: _actorName)],
      );

      final merged = mergeCastCrew([base], const []);

      expect(merged.single.id, 'm2');
      expect(merged.single.roles!.single.role, isNull);
    });

    test('after merge, the fetched character resolves via characterForItem', () {
      final base = testMediaItem(
        id: 'm3',
        year: 2012,
        roles: const [MediaRole(id: 'c1', tag: _actorName)],
      );
      final detailed = testMediaItem(
        id: 'm3',
        roles: const [MediaRole(id: 'c2', tag: _actorName, role: 'Captain Vega')],
      );

      final merged = mergeCastCrew([base], [detailed]).single;

      expect(characterForItem(_actorName, merged), 'Captain Vega');
    });
  });

  group('libraryMatchForCredit', () {
    final library = [
      testMediaItem(id: 'lib-mentalist', kind: MediaKind.show, title: 'The Mentalist', year: 2008, guid: 'plex://show/SHOWKEY'),
      testMediaItem(id: 'lib-prada', kind: MediaKind.movie, title: 'The Devil Wears Prada', year: 2006),
    ];

    test('matches by plex guid built from the credit type + ratingKey', () {
      const credit = PersonCredit(title: 'The Mentalist', year: 2008, mediaType: 'show', ratingKey: 'SHOWKEY');
      expect(libraryMatchForCredit(credit, library)?.id, 'lib-mentalist');
    });

    test('falls back to a case-insensitive title + year match when guids differ', () {
      // No guid on the Prada library item, and the credit's ratingKey won't
      // build a matching guid — so title+year carries it.
      const credit = PersonCredit(title: 'the devil wears prada', year: 2006, mediaType: 'movie', ratingKey: 'OTHERKEY');
      expect(libraryMatchForCredit(credit, library)?.id, 'lib-prada');
    });

    test('returns null when the title is not in the library', () {
      const credit = PersonCredit(title: 'Land of the Dead', year: 2005, mediaType: 'movie', ratingKey: 'X');
      expect(libraryMatchForCredit(credit, library), isNull);
    });

    test('a title match with a different year is not a match', () {
      const credit = PersonCredit(title: 'The Devil Wears Prada', year: 1999, mediaType: 'movie', ratingKey: 'X');
      expect(libraryMatchForCredit(credit, library), isNull);
    });
  });
}
