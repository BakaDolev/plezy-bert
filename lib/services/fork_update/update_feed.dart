/// The fork's own update feeds (fork-only; never upstream).
///
/// Every release on the fork's GitHub repo carries feeds that describe only
/// itself: `appcast.xml` (WinSparkle's format, for Windows) and `android.json`.
/// Stable devices follow GitHub's "latest" release, which never points at a
/// pre-release; beta devices take the newest release of any kind. No feed is
/// ever re-uploaded, so one can't go missing or stale while a build is
/// published, and promoting a beta hands everyday devices the exact files the
/// test devices ran.
library;

import 'dart:convert';

import 'package:xml/xml.dart';

/// The GitHub repo the fork publishes its builds to.
const String kForkReleasesRepo = 'BakaDolev/plezy-bert';

const String _sparkleNamespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

/// Which releases a device follows.
enum UpdateChannel { stable, beta }

/// Which of a release's two feeds to read.
enum UpdateFeedKind {
  windows('appcast.xml'),
  android('android.json');

  const UpdateFeedKind(this.assetName);

  final String assetName;
}

/// A fork release tag is `v<fork version>`, e.g. `v0.0.2`. Returns the
/// version's three numbers, or null for any other tag.
(int, int, int)? forkVersionFromTag(String tag) {
  final match = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$').firstMatch(tag.trim());
  if (match == null) return null;
  return (int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!));
}

bool _newer((int, int, int) a, (int, int, int) b) =>
    a.$1 != b.$1 ? a.$1 > b.$1 : (a.$2 != b.$2 ? a.$2 > b.$2 : a.$3 > b.$3);

/// The stable channel's feed: the newest full (non-pre-release) release.
Uri stableFeedUri(UpdateFeedKind kind) =>
    Uri.parse('https://github.com/$kForkReleasesRepo/releases/latest/download/${kind.assetName}');

/// The GitHub API list the beta channel reads (drafts are never visible to it).
Uri releasesApiUri() => Uri.parse('https://api.github.com/repos/$kForkReleasesRepo/releases?per_page=20');

/// The beta channel's feed: that of the release with the highest version
/// among those carrying [kind]'s feed. The version decides, not the date: an
/// older release that was edited later must never win. (The release guard
/// gives every build a higher version, so this is also the highest build.)
Uri? betaFeedUriFromReleases(Object? releases, UpdateFeedKind kind) {
  if (releases is! List) return null;
  (int, int, int)? best;
  String? bestTag;
  for (final release in releases) {
    if (release is! Map || release['draft'] == true) continue;
    final tag = release['tag_name'];
    if (tag is! String) continue;
    final version = forkVersionFromTag(tag);
    if (version == null) continue;
    final assets = release['assets'];
    final hasFeed = assets is List && assets.any((asset) => asset is Map && asset['name'] == kind.assetName);
    if (!hasFeed) continue;
    if (best == null || _newer(version, best)) {
      best = version;
      bestTag = tag.trim();
    }
  }
  if (bestTag == null) return null;
  return Uri.https('github.com', '/$kForkReleasesRepo/releases/download/$bestTag/${kind.assetName}');
}

/// Where an update may be downloaded from: GitHub over https, or this PC
/// when a test build reads a local feed ([allowLocal]).
bool isAllowedDownload(Uri url, {bool allowLocal = false}) =>
    (url.scheme == 'https' && url.host == 'github.com') ||
    (allowLocal &&
        (url.scheme == 'http' || url.scheme == 'https') &&
        (url.host == '127.0.0.1' || url.host == 'localhost'));

/// The Windows update an appcast offers.
class AppcastItem {
  const AppcastItem({
    required this.build,
    required this.version,
    this.notes,
    this.installerUrl,
    this.installerSize,
    this.edSignature,
  });

  /// Compared with this app's own build number.
  final int build;

  /// The fork version, e.g. "0.0.2".
  final String version;

  /// The release notes, when the feed carries them inline.
  final String? notes;

  /// The installer, its size in bytes and its EdDSA signature (base64); null
  /// when the feed lacks one or names a download from anywhere else.
  final Uri? installerUrl;
  final int? installerSize;
  final String? edSignature;

  bool get isInstallable => installerUrl != null && installerSize != null && edSignature != null;
}

/// The highest Windows item in an appcast (WinSparkle's format), or null when
/// there is none or the text is not one.
AppcastItem? parseAppcast(String xml, {bool allowLocal = false}) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml);
  } on XmlException {
    return null;
  }
  AppcastItem? best;
  for (final item in document.findAllElements('item')) {
    final windows = item
        .findElements('enclosure')
        .where((enclosure) => enclosure.getAttribute('os', namespaceUri: _sparkleNamespace) == 'windows')
        .firstOrNull;
    if (windows == null) continue;
    final build = int.tryParse(
      (item.findElements('version', namespaceUri: _sparkleNamespace).firstOrNull?.innerText ??
              windows.getAttribute('version', namespaceUri: _sparkleNamespace) ??
              '')
          .trim(),
    );
    if (build == null) continue;
    final version =
        item.findElements('shortVersionString', namespaceUri: _sparkleNamespace).firstOrNull?.innerText.trim() ??
        '$build';
    final notes = item.findElements('description').firstOrNull?.innerText.trim();
    final url = Uri.tryParse(windows.getAttribute('url') ?? '');
    final size = int.tryParse(windows.getAttribute('length') ?? '');
    final signature = windows.getAttribute('edSignature', namespaceUri: _sparkleNamespace)?.trim();
    final installable =
        url != null &&
        isAllowedDownload(url, allowLocal: allowLocal) &&
        size != null &&
        size > 0 &&
        signature != null &&
        RegExp(r'^[A-Za-z0-9+/]{86}==$').hasMatch(signature);
    if (best == null || build > best.build) {
      best = AppcastItem(
        build: build,
        version: version,
        notes: (notes == null || notes.isEmpty) ? null : notes,
        installerUrl: installable ? url : null,
        installerSize: installable ? size : null,
        edSignature: installable ? signature : null,
      );
    }
  }
  return best;
}

/// One APK in an Android feed.
class ApkAsset {
  const ApkAsset({required this.url, required this.versionCode, required this.sha256, required this.size});

  final Uri url;
  final int versionCode;

  /// Lower-case hex; the download is checked against it before installing.
  final String sha256;
  final int size;
}

/// What an Android feed offers: one build, with an APK per CPU type.
class AndroidFeed {
  const AndroidFeed({required this.build, required this.version, required this.notes, required this.apks});

  final int build;
  final String version;
  final String notes;

  /// Keyed by ABI: `arm64-v8a`, `armeabi-v7a`.
  final Map<String, ApkAsset> apks;
}

/// An Android feed, from parsed JSON or its text; null when it is not one.
/// An APK entry that is not an https download from github.com (or this PC,
/// [allowLocal]), or lacks a well-formed checksum, size or versionCode, is
/// dropped.
AndroidFeed? parseAndroidFeed(Object? data, {bool allowLocal = false}) {
  Object? json = data;
  if (json is String) {
    try {
      json = jsonDecode(json);
    } on FormatException {
      return null;
    }
  }
  if (json is! Map) return null;
  final build = json['build'];
  if (build is! int) return null;
  final apks = <String, ApkAsset>{};
  final entries = json['apks'];
  if (entries is Map) {
    for (final MapEntry(:key, :value) in entries.entries) {
      final asset = _apkAsset(value, allowLocal: allowLocal);
      if (key is String && asset != null) apks[key] = asset;
    }
  }
  return AndroidFeed(
    build: build,
    version: json['version'] is String ? json['version'] as String : '$build',
    notes: json['notes'] is String ? json['notes'] as String : '',
    apks: apks,
  );
}

ApkAsset? _apkAsset(Object? entry, {required bool allowLocal}) {
  if (entry is! Map) return null;
  final url = Uri.tryParse(entry['url'] is String ? entry['url'] as String : '');
  final versionCode = entry['versionCode'];
  final sha256 = entry['sha256'];
  final size = entry['size'];
  if (url == null || !isAllowedDownload(url, allowLocal: allowLocal)) return null;
  if (versionCode is! int || size is! int || size <= 0) return null;
  if (sha256 is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) return null;
  return ApkAsset(url: url, versionCode: versionCode, sha256: sha256.toLowerCase(), size: size);
}

enum UpdateVerdict { upToDate, available, skipped }

/// Only a higher build is an update; one the user skipped is not offered again
/// (a newer one is).
UpdateVerdict decideUpdate({required int own, required int remote, int? skipped}) {
  if (remote <= own) return UpdateVerdict.upToDate;
  if (skipped == remote) return UpdateVerdict.skipped;
  return UpdateVerdict.available;
}

/// This app's build number from `PackageInfo.buildNumber`. Android split APKs
/// carry 1000 × the CPU type on top of it (Flutter's `--split-per-abi`), so
/// only the last three digits are the build; release builds stay below 1000.
int? ownBuildNumber(String packageBuildNumber, {required bool android}) {
  final value = int.tryParse(packageBuildNumber.trim());
  if (value == null) return null;
  return android ? value % 1000 : value;
}
