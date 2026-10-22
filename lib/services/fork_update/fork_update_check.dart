/// One look at the fork's update feed for a channel (fork-only; never upstream).
library;

import '../../utils/app_logger.dart';
import 'update_feed.dart';

/// What a GET returned: the status code and the body (parsed JSON, or text).
typedef FeedResponse = ({int statusCode, Object? data});
typedef FeedGet = Future<FeedResponse> Function(Uri uri);

/// Test builds only (`--dart-define=FORK_UPDATE_FEED_OVERRIDE=http://127.0.0.1:8765/`):
/// a folder serving `appcast.xml` / `android.json` stands in for GitHub, on
/// either channel. Empty, and so unused, in every release build.
const String kForkUpdateFeedOverride = String.fromEnvironment('FORK_UPDATE_FEED_OVERRIDE');

enum ForkUpdateStatus {
  upToDate,
  available,

  /// Newer, but the user chose to skip this build.
  skipped,

  /// The channel has nothing published yet (stable before the first promote).
  noRelease,

  /// The network, GitHub or the feed let us down; worth saying on a manual check.
  failed,
}

class ForkUpdateCheck {
  const ForkUpdateCheck(
    this.status, {
    this.feedUri,
    this.build,
    this.version,
    this.notes,
    this.androidFeed,
    this.appcast,
  });

  final ForkUpdateStatus status;

  /// The feed that was read.
  final Uri? feedUri;
  final int? build;
  final String? version;
  final String? notes;

  /// The APKs on offer, for [UpdateFeedKind.android].
  final AndroidFeed? androidFeed;

  /// The installer on offer, for [UpdateFeedKind.windows].
  final AppcastItem? appcast;
}

/// Reads [channel]'s [kind] feed and compares it with [ownBuild]. Never
/// throws: anything that goes wrong is [ForkUpdateStatus.failed].
Future<ForkUpdateCheck> checkForkFeed({
  required UpdateChannel channel,
  required UpdateFeedKind kind,
  required int ownBuild,
  int? skipped,
  required FeedGet get,
  String feedOverride = kForkUpdateFeedOverride,
}) async {
  try {
    final Uri? feedUri;
    switch (channel) {
      case _ when feedOverride.isNotEmpty:
        feedUri = Uri.parse(feedOverride).resolve(kind.assetName);
      case UpdateChannel.stable:
        feedUri = stableFeedUri(kind);
      case UpdateChannel.beta:
        final releases = await get(releasesApiUri());
        if (releases.statusCode != 200) {
          appLogger.w('Fork update: release list returned HTTP ${releases.statusCode}');
          return const ForkUpdateCheck(ForkUpdateStatus.failed);
        }
        feedUri = betaFeedUriFromReleases(releases.data, kind);
    }
    if (feedUri == null) return const ForkUpdateCheck(ForkUpdateStatus.noRelease);

    final response = await get(feedUri);
    if (response.statusCode == 404) return ForkUpdateCheck(ForkUpdateStatus.noRelease, feedUri: feedUri);
    if (response.statusCode != 200) {
      appLogger.w('Fork update: feed returned HTTP ${response.statusCode}');
      return ForkUpdateCheck(ForkUpdateStatus.failed, feedUri: feedUri);
    }

    final allowLocal = feedOverride.isNotEmpty;
    final int build;
    final String version;
    final String? notes;
    AndroidFeed? androidFeed;
    AppcastItem? appcast;
    switch (kind) {
      case UpdateFeedKind.windows:
        final data = response.data;
        appcast = data is String ? parseAppcast(data, allowLocal: allowLocal) : null;
        if (appcast == null || !appcast.isInstallable) {
          appLogger.w('Fork update: the appcast offers no installer this build can use');
          return ForkUpdateCheck(ForkUpdateStatus.failed, feedUri: feedUri);
        }
        (build, version, notes) = (appcast.build, appcast.version, appcast.notes);
      case UpdateFeedKind.android:
        androidFeed = parseAndroidFeed(response.data, allowLocal: allowLocal);
        if (androidFeed == null) return ForkUpdateCheck(ForkUpdateStatus.failed, feedUri: feedUri);
        (build, version, notes) = (androidFeed.build, androidFeed.version, androidFeed.notes);
    }

    final status = switch (decideUpdate(own: ownBuild, remote: build, skipped: skipped)) {
      UpdateVerdict.upToDate => ForkUpdateStatus.upToDate,
      UpdateVerdict.available => ForkUpdateStatus.available,
      UpdateVerdict.skipped => ForkUpdateStatus.skipped,
    };
    return ForkUpdateCheck(
      status,
      feedUri: feedUri,
      build: build,
      version: version,
      notes: notes,
      androidFeed: androidFeed,
      appcast: appcast,
    );
  } catch (error, stackTrace) {
    appLogger.w('Fork update check failed', error: error, stackTrace: stackTrace);
    return const ForkUpdateCheck(ForkUpdateStatus.failed);
  }
}
