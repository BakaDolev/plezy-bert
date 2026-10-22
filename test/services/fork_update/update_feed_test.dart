import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/fork_update/update_feed.dart';

// Upstream's real 2.23.0 appcast (its `appcast` branch), trimmed of the macOS signature.
const _upstreamAppcast = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Plezy Updates</title>
    <item>
      <title>Version 2.23.0</title>
      <sparkle:version>153</sparkle:version>
      <sparkle:shortVersionString>2.23.0</sparkle:shortVersionString>
      <sparkle:releaseNotesLink>https://gh-html.edde746.dev/edde746/plezy/2.23.0</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/edde746/plezy/releases/download/2.23.0/plezy-macos.dmg"
       length="72964428" type="application/octet-stream" sparkle:edSignature="x" sparkle:os="macos" />
      <enclosure url="https://github.com/edde746/plezy/releases/download/2.23.0/plezy-windows-installer.exe"
       length="105384808" type="application/octet-stream"
       sparkle:edSignature="y" sparkle:installerArguments="/SILENT /SP-" sparkle:os="windows" />
    </item>
  </channel>
</rss>''';

const _forkAppcast =
    '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Plezy Fork Updates</title>
    <item>
      <title>Plezy Fork 0.0.3</title>
      <sparkle:version>175</sparkle:version>
      <sparkle:shortVersionString>0.0.3</sparkle:shortVersionString>
      <description><![CDATA[<p>Fixed the thing.</p>]]></description>
      <enclosure url="https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.3/PlezyFork-0.0.3-setup.exe"
       length="58600000" type="application/octet-stream"
       sparkle:edSignature="$_signature" sparkle:installerArguments="/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART" sparkle:os="windows" />
    </item>
  </channel>
</rss>''';

// The shape of a real one: 64 bytes in base64.
const _signature = 'Q9t2tI4jkn8z5V3Vb1lm2X0d3F4c9QnU2bQ8aWl3nP5sXo1cL7hYk0rT6gE2mN4pZ8vR1uK3wJ5yH7dB9fA6eC==';

String _sha(String c) => List.filled(64, c).join();

Map<String, Object?> _release(
  String tag, {
  bool draft = false,
  bool prerelease = true,
  List<String> assets = const ['appcast.xml', 'android.json'],
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'assets': [
    for (final a in assets) {'name': a},
  ],
};

void main() {
  group('forkVersionFromTag', () {
    test('reads the fork version of a release tag', () {
      expect(forkVersionFromTag('v0.0.1'), (0, 0, 1));
      expect(forkVersionFromTag(' v1.12.3 '), (1, 12, 3));
    });

    test('ignores tags that are not fork release tags', () {
      expect(forkVersionFromTag('2.23.0'), isNull); // upstream-style
      expect(forkVersionFromTag('2.23.0-175'), isNull); // the fork's old style, never published
      expect(forkVersionFromTag('beta-feed'), isNull);
      expect(forkVersionFromTag('v1.0'), isNull);
      expect(forkVersionFromTag('v1.0.0-rc1'), isNull);
    });
  });

  group('feed URLs', () {
    test('stable follows GitHub latest, which never points at a pre-release', () {
      expect(
        stableFeedUri(UpdateFeedKind.windows).toString(),
        'https://github.com/BakaDolev/plezy-bert/releases/latest/download/appcast.xml',
      );
      expect(
        stableFeedUri(UpdateFeedKind.android).toString(),
        'https://github.com/BakaDolev/plezy-bert/releases/latest/download/android.json',
      );
    });

    test('beta picks the highest version, not the newest date, comparing numbers not text', () {
      final releases = [
        _release('v0.0.9'), // listed first, as if edited most recently
        _release('v0.0.10'),
        _release('v0.0.2', prerelease: false),
      ];
      expect(
        betaFeedUriFromReleases(releases, UpdateFeedKind.windows).toString(),
        'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.10/appcast.xml',
      );
      final crossing = [_release('v0.9.9'), _release('v1.0.0'), _release('v0.10.0')];
      expect(
        betaFeedUriFromReleases(crossing, UpdateFeedKind.windows).toString(),
        'https://github.com/BakaDolev/plezy-bert/releases/download/v1.0.0/appcast.xml',
      );
    });

    test('beta skips drafts, foreign tags and releases without that feed', () {
      final releases = [
        _release('v0.0.9', draft: true),
        _release('2.24.0'),
        _release('2.23.0-180'),
        _release('v0.0.8', assets: const ['appcast.xml']),
        _release('v0.0.7'),
      ];
      expect(
        betaFeedUriFromReleases(releases, UpdateFeedKind.android).toString(),
        'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.7/android.json',
      );
      expect(
        betaFeedUriFromReleases(releases, UpdateFeedKind.windows).toString(),
        'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.8/appcast.xml',
      );
    });

    test('beta has nothing when the list is empty or not a list', () {
      expect(betaFeedUriFromReleases(const [], UpdateFeedKind.windows), isNull);
      expect(betaFeedUriFromReleases({'message': 'Not Found'}, UpdateFeedKind.windows), isNull);
      expect(betaFeedUriFromReleases(null, UpdateFeedKind.windows), isNull);
    });
  });

  group('parseAppcast', () {
    test('reads our format', () {
      final item = parseAppcast(_forkAppcast)!;
      expect(item.build, 175);
      expect(item.version, '0.0.3');
      expect(item.notes, '<p>Fixed the thing.</p>');
      expect(
        item.installerUrl.toString(),
        'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.3/PlezyFork-0.0.3-setup.exe',
      );
      expect(item.installerSize, 58600000);
      expect(item.edSignature, _signature);
      expect(item.isInstallable, isTrue);
    });

    test("reads upstream's real appcast (its Windows item)", () {
      final item = parseAppcast(_upstreamAppcast)!;
      expect(item.build, 153);
      expect(item.version, '2.23.0');
      expect(item.notes, isNull);
      expect(item.isInstallable, isFalse, reason: 'its signature field is not a real one');
    });

    test('an installer from anywhere but GitHub is not installable; this PC only for a local test feed', () {
      final local = _forkAppcast.replaceAll(
        'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.3/',
        'http://127.0.0.1:8765/',
      );
      expect(parseAppcast(local)!.isInstallable, isFalse);
      expect(parseAppcast(local, allowLocal: true)!.isInstallable, isTrue);
      final elsewhere = _forkAppcast.replaceAll('https://github.com/', 'https://github.example.com/');
      expect(parseAppcast(elsewhere, allowLocal: true)!.isInstallable, isFalse);
      final unsized = _forkAppcast.replaceAll('length="58600000"', 'length="0"');
      expect(parseAppcast(unsized)!.isInstallable, isFalse);
    });

    test('returns null without a Windows enclosure, a build number, or valid XML', () {
      expect(parseAppcast(_upstreamAppcast.replaceAll('sparkle:os="windows"', 'sparkle:os="linux"')), isNull);
      expect(parseAppcast(_forkAppcast.replaceAll('<sparkle:version>175</sparkle:version>', '')), isNull);
      expect(parseAppcast('<rss><channel></rss'), isNull);
      expect(parseAppcast('Not Found'), isNull);
    });
  });

  group('parseAndroidFeed', () {
    Map<String, Object?> feed({String? url, String? sha, Object? versionCode}) => {
      'version': '0.0.3',
      'build': 175,
      'tag': 'v0.0.3',
      'notes': 'Fixed the thing.',
      'apks': {
        'arm64-v8a': {
          'url':
              url ??
              'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.3/PlezyFork-0.0.3-phone-arm64-v8a.apk',
          'versionCode': versionCode ?? 2175,
          'sha256': sha ?? _sha('a'),
          'size': 61000000,
        },
        'armeabi-v7a': {
          'url': 'https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.3/PlezyFork-0.0.3-tv-armeabi-v7a.apk',
          'versionCode': 1175,
          'sha256': _sha('b'),
          'size': 59000000,
        },
      },
    };

    test('reads a good feed, from parsed JSON or text', () {
      for (final input in [feed(), '{"version":"0.0.3","build":175,"tag":"v0.0.3","notes":"n","apks":{}}']) {
        expect(parseAndroidFeed(input), isNotNull);
      }
      final f = parseAndroidFeed(feed())!;
      expect(f.build, 175);
      expect(f.version, '0.0.3');
      expect(f.notes, 'Fixed the thing.');
      expect(f.apks['arm64-v8a']!.versionCode, 2175);
      expect(f.apks['armeabi-v7a']!.sha256, _sha('b'));
    });

    test('drops an APK entry that is unsafe or malformed', () {
      expect(parseAndroidFeed(feed(url: 'http://github.com/x.apk'))!.apks.containsKey('arm64-v8a'), isFalse);
      expect(parseAndroidFeed(feed(url: 'https://evil.example/x.apk'))!.apks.containsKey('arm64-v8a'), isFalse);
      expect(parseAndroidFeed(feed(sha: 'abc'))!.apks.containsKey('arm64-v8a'), isFalse);
      expect(parseAndroidFeed(feed(versionCode: '2175'))!.apks.containsKey('arm64-v8a'), isFalse);
      expect(parseAndroidFeed(feed(url: 'https://evil.example/x.apk'))!.apks.containsKey('armeabi-v7a'), isTrue);
    });

    test('returns null for bad JSON or a feed without a build number', () {
      expect(parseAndroidFeed('{nope'), isNull);
      expect(parseAndroidFeed({'version': '2.23.0'}), isNull);
      expect(parseAndroidFeed(const ['x']), isNull);
    });
  });

  group('decide', () {
    test('only a higher build is an update', () {
      expect(decideUpdate(own: 175, remote: 175), UpdateVerdict.upToDate);
      expect(decideUpdate(own: 176, remote: 175), UpdateVerdict.upToDate);
      expect(decideUpdate(own: 174, remote: 175), UpdateVerdict.available);
    });

    test('a skipped build is not offered again, a newer one is', () {
      expect(decideUpdate(own: 174, remote: 175, skipped: 175), UpdateVerdict.skipped);
      expect(decideUpdate(own: 174, remote: 176, skipped: 175), UpdateVerdict.available);
    });
  });

  group('own build number', () {
    test('Windows reads it as is; Android drops the per-ABI thousands', () {
      expect(ownBuildNumber('175', android: false), 175);
      expect(ownBuildNumber('2175', android: true), 175);
      expect(ownBuildNumber('1175', android: true), 175);
      expect(ownBuildNumber('', android: false), isNull);
      expect(ownBuildNumber('abc', android: true), isNull);
    });
  });
}
