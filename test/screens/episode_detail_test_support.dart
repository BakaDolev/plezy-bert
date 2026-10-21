import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_role.dart';
import 'package:plezy/media/media_server_client.dart';

/// Builds a Plex-backed episode [MediaItem] with the fields the episode
/// detail screen (and its later tasks) read. Uses [MediaItem.plex] directly
/// rather than the backend-dispatching synthetic factory: the synthetic
/// factory's field set omits `parentIndex`/`grandparentId`/`grandparentTitle`/
/// `roles`/`writers`/`directors`/`viewOffsetMs`, all of which callers here need.
MediaItem fakeEpisode({
  String id = 'ep1',
  String? title = 'Episode',
  int? index = 1,
  int? parentIndex = 1,
  String? grandparentId = 'show1',
  String? grandparentTitle = 'Test Show',
  String? summary,
  List<MediaRole>? roles,
  List<String>? writers,
  List<String>? directors,
  int? viewOffsetMs,
  int? viewCount,
  String? thumbPath,
  String? grandparentArtPath,
  int? durationMs,
  String? originallyAvailableAt,
  String? contentRating,
  double? rating,
}) => MediaItem.plex(
  id: id,
  kind: MediaKind.episode,
  serverId: 'srv1',
  serverName: 'Server',
  title: title,
  index: index,
  parentIndex: parentIndex,
  grandparentId: grandparentId,
  grandparentTitle: grandparentTitle,
  summary: summary,
  roles: roles,
  writers: writers,
  directors: directors,
  viewOffsetMs: viewOffsetMs,
  viewCount: viewCount,
  thumbPath: thumbPath,
  grandparentArtPath: grandparentArtPath,
  durationMs: durationMs,
  originallyAvailableAt: originallyAvailableAt,
  contentRating: contentRating,
  rating: rating,
);

/// Minimal fake — returns [item] from fetchItem; everything else no-ops.
///
/// [serverId]/[serverName]/[backend]/[close] are implemented concretely (not
/// routed through [noSuchMethod]) because [testMultiServer] registers this
/// client on a [MultiServerManager], which reads `client.serverId`
/// synchronously during registration and calls `client.close()` when the
/// manager is disposed at test teardown — the inherited `Object.noSuchMethod`
/// throws for any unimplemented member reached this way.
class FakeEpisodeClient implements MediaServerClient {
  FakeEpisodeClient({required this.item, ServerId? serverId, this.serverName = 'Server'})
    : serverId = serverId ?? ServerId('srv1');
  final MediaItem? item;
  int fetchItemCalls = 0;
  int markWatchedCalls = 0;
  int markUnwatchedCalls = 0;

  @override
  final ServerId serverId;

  @override
  final String? serverName;

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  void close() {}

  @override
  Future<MediaItem?> fetchItem(String id) async {
    fetchItemCalls++;
    return item;
  }

  // Concrete (not routed through noSuchMethod) so the watched-toggle action
  // row can be tap-tested through WatchActions.setWatched (watch_actions.dart)
  // without hitting the throwing fallback below.
  @override
  Future<void> markWatched(MediaItem item) async {
    markWatchedCalls++;
  }

  @override
  Future<void> markUnwatched(MediaItem item) async {
    markUnwatchedCalls++;
  }

  // Concrete (not routed through noSuchMethod) so the hero still image
  // (OptimizedMediaImage, via MediaImageHelper.getOptimizedImageUrl) can
  // build without hitting the throwing fallback below. An empty URL is an
  // "unresolved" image to OptimizedMediaImage, same as the real client
  // returns offline/without a server — it renders its placeholder, not a
  // crash (mirrors the same stub in media_detail_screen_test.dart and the
  // music detail screen tests).
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) => '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
