import '../media/media_item.dart';
import '../services/enrichment/person_online_page.dart';

/// The library title that corresponds to an online filmography [credit], or
/// null when the person's title isn't in your library. Lets the actor page
/// badge a filmography row "On {server}" and link it to the local item.
///
/// Matches by Plex guid (`plex://{type}/{ratingKey}`) first — exact when both
/// sides use the Plex agent — then falls back to a case-insensitive title +
/// year match.
MediaItem? libraryMatchForCredit(PersonCredit credit, List<MediaItem> library) {
  final ratingKey = credit.ratingKey;
  final guid = (ratingKey != null && ratingKey.isNotEmpty && credit.mediaType.isNotEmpty)
      ? 'plex://${credit.mediaType}/$ratingKey'
      : null;
  final title = credit.title.trim().toLowerCase();

  MediaItem? titleYearMatch;
  for (final item in library) {
    if (guid != null && item.guid == guid) return item;
    if (titleYearMatch == null &&
        title.isNotEmpty &&
        (item.title ?? '').trim().toLowerCase() == title &&
        item.year == credit.year) {
      titleYearMatch = item;
    }
  }
  return titleYearMatch;
}

/// Folds the cast/crew from [detailed] onto [base], matched by id.
///
/// Plex's per-person media list (`/library/people/{id}/media`) carries each
/// cast member's *name* ([MediaRole.tag]) but not the *character* they played
/// ([MediaRole.role] is null), and omits the crew name lists — so the library
/// grid can't caption "as \<character>". A batched full-metadata fetch does
/// carry them; this merges those cast/crew fields back onto the person-media
/// items so `characterForItem` can caption each title. Every other field (watch
/// state, thumbnails, year) is taken from [base]. Items with no id match in
/// [detailed] pass through unchanged, so a partial or failed fetch degrades
/// gracefully to the person-media data.
List<MediaItem> mergeCastCrew(List<MediaItem> base, List<MediaItem> detailed) {
  if (detailed.isEmpty) return base;
  final byId = {for (final d in detailed) d.id: d};
  return [
    for (final item in base)
      if (byId[item.id] case final d?)
        item.copyWith(
          roles: d.roles ?? item.roles,
          directors: d.directors ?? item.directors,
          writers: d.writers ?? item.writers,
          producers: d.producers ?? item.producers,
        )
      else
        item,
  ];
}
