import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/fork_update/fork_update_check.dart';
import 'package:plezy/services/fork_update/update_feed.dart';

final _signature = '${'A' * 86}==';

String _appcast(int build, {String? url, String? signature}) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>0.0.$build</sparkle:shortVersionString>
      <description><![CDATA[<p>Build $build.</p>]]></description>
      <enclosure url="${url ?? 'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.$build/PlezyFork-0.0.$build-setup.exe'}"
       length="1" type="application/octet-stream" sparkle:edSignature="${signature ?? _signature}" sparkle:os="windows" />
    </item>
  </channel>
</rss>''';

Map<String, Object?> _androidFeed(int build) => {
  'version': '0.0.$build',
  'build': build,
  'notes': 'Build $build.',
  'apks': {
    'arm64-v8a': {
      'url': 'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.$build/a.apk',
      'versionCode': 2000 + build,
      'sha256': List.filled(64, 'a').join(),
      'size': 1,
    },
  },
};

Map<String, Object?> _release(int build, {bool prerelease = true}) => {
  'tag_name': 'v0.0.$build',
  'draft': false,
  'prerelease': prerelease,
  'assets': [
    {'name': 'appcast.xml'},
    {'name': 'android.json'},
  ],
};

/// A fake network: each URL answers with what [routes] says; anything else is 404.
FeedGet _fake(Map<String, FeedResponse> routes, {List<Uri>? log}) => (uri) async {
  log?.add(uri);
  return routes[uri.toString()] ?? (statusCode: 404, data: 'Not Found');
};

const _stableAppcast = 'https://github.com/BakaDolev/plezy-bert/releases/latest/download/appcast.xml';
const _stableAndroid = 'https://github.com/BakaDolev/plezy-bert/releases/latest/download/android.json';
const _api = 'https://api.github.com/repos/BakaDolev/plezy-bert/releases?per_page=20';

void main() {
  group('stable', () {
    test('a higher build is available, with what the feed says about it', () async {
      final check = await checkForkFeed(
        channel: UpdateChannel.stable,
        kind: UpdateFeedKind.windows,
        ownBuild: 174,
        get: _fake({_stableAppcast: (statusCode: 200, data: _appcast(175))}),
      );
      expect(check.status, ForkUpdateStatus.available);
      expect(check.feedUri.toString(), _stableAppcast);
      expect(check.build, 175);
      expect(check.version, '0.0.175');
      expect(check.notes, '<p>Build 175.</p>');
      expect(check.appcast!.installerUrl!.path, endsWith('PlezyFork-0.0.175-setup.exe'));
      expect(check.appcast!.edSignature, _signature);
    });

    test('a Windows build without a signed GitHub installer is never offered', () async {
      for (final appcast in [
        _appcast(175, signature: 'z'),
        _appcast(175, url: 'https://example.com/PlezyFork-0.0.175-setup.exe'),
        _appcast(175, url: 'http://127.0.0.1:8765/PlezyFork-0.0.175-setup.exe'),
      ]) {
        final check = await checkForkFeed(
          channel: UpdateChannel.stable,
          kind: UpdateFeedKind.windows,
          ownBuild: 174,
          get: _fake({_stableAppcast: (statusCode: 200, data: appcast)}),
        );
        expect(check.status, ForkUpdateStatus.failed, reason: appcast);
      }
    });

    test('the same build is up to date', () async {
      final check = await checkForkFeed(
        channel: UpdateChannel.stable,
        kind: UpdateFeedKind.windows,
        ownBuild: 175,
        get: _fake({_stableAppcast: (statusCode: 200, data: _appcast(175))}),
      );
      expect(check.status, ForkUpdateStatus.upToDate);
    });

    test('no stable release yet is not a failure', () async {
      final check = await checkForkFeed(
        channel: UpdateChannel.stable,
        kind: UpdateFeedKind.windows,
        ownBuild: 174,
        get: _fake({}),
      );
      expect(check.status, ForkUpdateStatus.noRelease);
    });

    test('a server error or a feed that does not parse is a failure', () async {
      for (final response in <FeedResponse>[
        (statusCode: 500, data: 'oops'),
        (statusCode: 200, data: '<html>rate limited</html>'),
        (statusCode: 200, data: null),
      ]) {
        final check = await checkForkFeed(
          channel: UpdateChannel.stable,
          kind: UpdateFeedKind.windows,
          ownBuild: 174,
          get: _fake({_stableAppcast: response}),
        );
        expect(check.status, ForkUpdateStatus.failed, reason: '$response');
      }
    });

    test('a network error is a failure, not a crash', () async {
      final check = await checkForkFeed(
        channel: UpdateChannel.stable,
        kind: UpdateFeedKind.windows,
        ownBuild: 174,
        get: (_) async => throw Exception('offline'),
      );
      expect(check.status, ForkUpdateStatus.failed);
    });

    test('Android reads its own feed, and honours a skipped build', () async {
      final get = _fake({_stableAndroid: (statusCode: 200, data: _androidFeed(175))});
      final check = await checkForkFeed(
        channel: UpdateChannel.stable,
        kind: UpdateFeedKind.android,
        ownBuild: 174,
        get: get,
      );
      expect(check.status, ForkUpdateStatus.available);
      expect(check.androidFeed!.apks['arm64-v8a']!.versionCode, 2175);

      final skipped = await checkForkFeed(
        channel: UpdateChannel.stable,
        kind: UpdateFeedKind.android,
        ownBuild: 174,
        skipped: 175,
        get: get,
      );
      expect(skipped.status, ForkUpdateStatus.skipped);
    });
  });

  test('a test build reads its local feed on either channel, never GitHub', () async {
    for (final channel in UpdateChannel.values) {
      final log = <Uri>[];
      final check = await checkForkFeed(
        channel: channel,
        kind: UpdateFeedKind.windows,
        ownBuild: 998,
        feedOverride: 'http://127.0.0.1:8765/',
        get: _fake({'http://127.0.0.1:8765/appcast.xml': (statusCode: 200, data: _appcast(999))}, log: log),
      );
      expect(check.status, ForkUpdateStatus.available, reason: '$channel');
      expect(log.map((u) => u.host), ['127.0.0.1']);
    }
    final local = await checkForkFeed(
      channel: UpdateChannel.beta,
      kind: UpdateFeedKind.windows,
      ownBuild: 998,
      feedOverride: 'http://127.0.0.1:8765/',
      get: _fake({
        'http://127.0.0.1:8765/appcast.xml': (
          statusCode: 200,
          data: _appcast(999, url: 'http://127.0.0.1:8765/PlezyFork-0.0.999-setup.exe'),
        ),
      }),
    );
    expect(local.status, ForkUpdateStatus.available, reason: 'its own installer may come from this PC too');
  });

  group('beta', () {
    test('reads the feed of the newest release, pre-release or not', () async {
      final log = <Uri>[];
      final check = await checkForkFeed(
        channel: UpdateChannel.beta,
        kind: UpdateFeedKind.windows,
        ownBuild: 175,
        get: _fake({
          _api: (statusCode: 200, data: [_release(175, prerelease: false), _release(176)]),
          'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.176/appcast.xml': (
            statusCode: 200,
            data: _appcast(176),
          ),
        }, log: log),
      );
      expect(check.status, ForkUpdateStatus.available);
      expect(check.build, 176);
      expect(log.map((u) => u.toString()), [
        _api,
        'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.176/appcast.xml',
      ]);
    });

    test('no releases at all is "no release"; an API refusal is a failure', () async {
      final empty = await checkForkFeed(
        channel: UpdateChannel.beta,
        kind: UpdateFeedKind.windows,
        ownBuild: 175,
        get: _fake({_api: (statusCode: 200, data: const [])}),
      );
      expect(empty.status, ForkUpdateStatus.noRelease);

      final limited = await checkForkFeed(
        channel: UpdateChannel.beta,
        kind: UpdateFeedKind.windows,
        ownBuild: 175,
        get: _fake({
          _api: (statusCode: 403, data: {'message': 'API rate limit exceeded'}),
        }),
      );
      expect(limited.status, ForkUpdateStatus.failed);
    });
  });
}
