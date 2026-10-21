import 'package:flutter/material.dart';
import '../media/media_item.dart';
import '../media/media_role.dart';
import '../screens/actor_media_screen.dart';

/// Opens the actor's library titles (Plex-style). [source] supplies
/// serverId/serverName/backend. No-ops if the role has no resolvable person id
/// or the source has no server.
void navigateToActorMedia(BuildContext context, MediaRole role, MediaItem source) {
  final personId = role.id;
  final serverId = source.serverId;
  if (personId == null || serverId == null) return;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ActorMediaScreen(
        actorName: role.tag,
        personId: personId,
        personTagKey: role.tagKey,
        actorThumb: role.thumbPath,
        characterName: role.role,
        serverId: serverId,
        serverName: source.serverName,
        backend: source.backend,
      ),
    ),
  );
}
