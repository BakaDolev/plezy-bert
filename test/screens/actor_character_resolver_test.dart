import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_role.dart';
import 'package:plezy/screens/actor_character_resolver.dart';

import '../test_helpers/media_items.dart';

const _actorName = 'Bryan Cranston';

void main() {
  group('characterForItem (matches by name, not id)', () {
    test('role whose tag matches the actor name returns the character', () {
      final item = testMediaItem(
        backend: MediaBackend.jellyfin,
        kind: MediaKind.show,
        // A different per-title id than any "person id" — matching is by tag.
        roles: const [MediaRole(id: 'credit-9137', tag: _actorName, role: 'Walter White')],
      );

      expect(characterForItem(_actorName, item), 'Walter White');
    });

    test('match is case-insensitive and trims surrounding whitespace', () {
      final item = testMediaItem(
        backend: MediaBackend.plex,
        kind: MediaKind.movie,
        roles: const [MediaRole(id: 'credit-1', tag: '  bryan cranston  ', role: 'Hal')],
      );

      expect(characterForItem(_actorName, item), 'Hal');
    });

    test('roles present but no tag matches returns null', () {
      final item = testMediaItem(
        backend: MediaBackend.jellyfin,
        kind: MediaKind.show,
        roles: const [MediaRole(id: 'credit-2', tag: 'Aaron Paul', role: 'Jesse Pinkman')],
      );

      expect(characterForItem(_actorName, item), isNull);
    });

    test('no roles but parentTitle set returns that value (Plex free-path)', () {
      final item = testMediaItem(backend: MediaBackend.plex, kind: MediaKind.movie, parentTitle: 'Some Character');

      expect(characterForItem(_actorName, item), 'Some Character');
    });

    test('neither a matching role nor parentTitle returns null', () {
      final item = testMediaItem(backend: MediaBackend.plex, kind: MediaKind.movie);

      expect(characterForItem(_actorName, item), isNull);
    });

    test('matching tag but an empty role falls through to parentTitle', () {
      final item = testMediaItem(
        backend: MediaBackend.jellyfin,
        kind: MediaKind.movie,
        parentTitle: 'Fallback Character',
        roles: const [MediaRole(id: 'credit-3', tag: _actorName, role: '')],
      );

      expect(characterForItem(_actorName, item), 'Fallback Character');
    });
  });

  group('copyWith(parentTitle:) render path', () {
    test('movie/series items have no displaySubtitle, so parentTitle is the fallback MediaCard renders', () {
      final movie = testMediaItem(backend: MediaBackend.plex, kind: MediaKind.movie);
      final series = testMediaItem(backend: MediaBackend.plex, kind: MediaKind.show);

      // MediaCard renders displaySubtitle first, falling back to parentTitle
      // only when it's null — confirm that fallback path is live for the
      // kinds this feature captions.
      expect(movie.displaySubtitle, isNull);
      expect(series.displaySubtitle, isNull);

      final captioned = movie.copyWith(parentTitle: 'Walter White');
      expect(captioned.parentTitle, 'Walter White');
      expect(captioned.displaySubtitle, isNull);
    });
  });
}
