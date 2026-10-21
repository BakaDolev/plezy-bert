import 'package:collection/collection.dart';

import '../media/media_item.dart';

/// Resolves the character a given actor played in [item], for captioning
/// the actor's filmography grid (`ActorMediaScreen`).
///
/// Matched by **name**, not id: Plex stamps a *per-title* id on every cast
/// credit, so the same person carries a different `role.id` on each title in
/// their filmography — matching on id fails across the list. The actor's
/// display name is stable, so [MediaRole.tag] (the credited name) is matched
/// against [actorName] case-insensitively and trimmed.
///
/// Two independent sources, tried in order:
/// 1. [MediaItem.roles] carries a cast/crew entry per person; the one whose
///    `tag` matches [actorName] carries the character name in its `role` field.
/// 2. Plex free-path: person-media rows may already deliver the character in
///    [MediaItem.parentTitle] with no extra fields needed.
///
/// Returns `null` when neither source has an answer; callers leave the
/// item's caption blank rather than guessing.
String? characterForItem(String actorName, MediaItem item) {
  final target = actorName.trim().toLowerCase();
  final role = item.roles?.firstWhereOrNull(
    (r) => r.tag.trim().toLowerCase() == target && (r.role?.isNotEmpty ?? false),
  );
  if (role != null) return role.role;

  if (item.parentTitle case final parentTitle? when parentTitle.isNotEmpty) {
    return parentTitle;
  }

  return null;
}
