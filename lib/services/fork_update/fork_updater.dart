/// The fork's updater (fork-only; never upstream).
///
/// Plezy decides whether an update exists and whether this is a moment it may
/// appear; only then does it show the fork's update dialog. On Windows the
/// dialog downloads the installer, checks our signature and runs it silently
/// ([WindowsUpdateFlow]); on Android it downloads and checks the APK and hands
/// it to Android's installer ([AndroidUpdateFlow]). WinSparkle is not used:
/// its own scheduler stays off (the runner and the installer write its
/// CheckForUpdates "0").
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../utils/media_server_http_client.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/fork_update_dialog.dart';
import '../settings_service.dart';
import '../update_service.dart';
import 'android_updater.dart';
import 'fork_update_check.dart';
import 'update_feed.dart';
import 'update_flow.dart';
import 'windows_updater.dart';

/// Test devices take beta builds first; everyday devices stay on stable.
const forkUpdateBetaPref = BoolPref('fork_update_beta');

UpdateChannel get forkUpdateChannel =>
    SettingsService.instance.read(forkUpdateBetaPref) ? UpdateChannel.beta : UpdateChannel.stable;

enum ForkUpdateOutcome {
  /// The update dialog is up.
  shown,
  upToDate,

  /// The channel has nothing published yet.
  noRelease,
  failed,

  /// Something plays; an update would interrupt it.
  playing,

  /// This install doesn't update itself.
  unavailable,

  /// Plezy doesn't look on its own on this computer ([updateChecksOff]).
  checksOff,
}

/// While the installer's /UPDATECHECKS=off file is there, Plezy never looks
/// for an update on its own: a test machine gets its updates from the silent
/// installer, and an offer must never pop up mid-test. The About button still
/// checks. Per user, like the install; /UPDATECHECKS=on (or deleting the
/// file) turns the checks back on.
@visibleForTesting
bool updateChecksOff({required Map<String, String> environment, bool Function(String path)? exists}) {
  final localAppData = environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) return false;
  return (exists ?? (path) => File(path).existsSync())('$localAppData\\Plezy Fork\\update-checks-off');
}

/// The order of one check: nothing while something plays (asked again after
/// the network round trip, which the user may have spent starting a title),
/// and only an available build is shown.
@visibleForTesting
Future<ForkUpdateOutcome> runForkUpdateCheck({
  required bool Function() isPlaybackActive,
  required Future<ForkUpdateCheck> Function() look,
  required Future<ForkUpdateOutcome> Function(ForkUpdateCheck check) show,
}) async {
  if (isPlaybackActive()) return ForkUpdateOutcome.playing;
  final check = await look();
  switch (check.status) {
    case ForkUpdateStatus.upToDate || ForkUpdateStatus.skipped:
      return ForkUpdateOutcome.upToDate;
    case ForkUpdateStatus.noRelease:
      return ForkUpdateOutcome.noRelease;
    case ForkUpdateStatus.failed:
      return ForkUpdateOutcome.failed;
    case ForkUpdateStatus.available:
      if (isPlaybackActive()) return ForkUpdateOutcome.playing;
      return show(check);
  }
}

class ForkUpdater {
  ForkUpdater._();

  static final ForkUpdater instance = ForkUpdater._();

  Future<ForkUpdateOutcome>? _running;

  /// An update-enabled build, installed by the installer on Windows (not
  /// winget, not a copied folder), or Android.
  static bool get isSupported =>
      UpdateService.isUpdateCheckAvailable &&
      (Platform.isWindows ? UpdateService.useNativeUpdater : Platform.isAndroid);

  /// Fork builds update from the fork's releases, from the About screen.
  /// Upstream's Settings → Updates group, which checks upstream's releases,
  /// stays hidden.
  static bool get replacesUpstreamUpdates => true;

  /// Looks for an update on this device's channel and shows it if there is
  /// one. [manual] is the About button: it also shows a build the user
  /// skipped. [dialogContext] is where the dialog opens (null when that
  /// screen is gone). A check already running is joined, not repeated.
  Future<ForkUpdateOutcome> check({
    required bool manual,
    required bool Function() isPlaybackActive,
    required BuildContext? Function() dialogContext,
  }) {
    if (!isSupported) return Future.value(ForkUpdateOutcome.unavailable);
    if (!manual && Platform.isWindows && updateChecksOff(environment: Platform.environment)) {
      return Future.value(ForkUpdateOutcome.checksOff);
    }
    return _running ??= runForkUpdateCheck(
      isPlaybackActive: isPlaybackActive,
      look: () => _look(manual: manual),
      show: (check) => _show(check, dialogContext: dialogContext),
    ).whenComplete(() => _running = null);
  }

  Future<ForkUpdateCheck> _look({required bool manual}) async {
    final ownBuild = ownBuildNumber((await PackageInfo.fromPlatform()).buildNumber, android: Platform.isAndroid);
    if (ownBuild == null) return const ForkUpdateCheck(ForkUpdateStatus.failed);
    // What an earlier update left behind (it ran; this build is it, or newer).
    unawaited(_updatesDir().then((dir) => purgeUpdates(Directory(dir))).catchError((_) {}));
    final skippedBuild = SettingsService.instance.read(forkUpdateSkippedBuildPref);
    return checkForkFeed(
      channel: forkUpdateChannel,
      kind: Platform.isWindows ? UpdateFeedKind.windows : UpdateFeedKind.android,
      ownBuild: ownBuild,
      skipped: !manual && skippedBuild > 0 ? skippedBuild : null,
      get: _get,
    );
  }

  Future<String> _updatesDir() => Platform.isWindows ? _windowsPlatform.updatesDir() : _androidPlatform.updatesDir();

  Future<ForkUpdateOutcome> _show(ForkUpdateCheck check, {required BuildContext? Function() dialogContext}) async {
    final isSamsung = Platform.isAndroid && await _androidPlatform.isSamsung();
    final context = dialogContext();
    if (context == null || !context.mounted) return ForkUpdateOutcome.failed;
    final ForkUpdateFlow flow = Platform.isWindows
        ? WindowsUpdateFlow(
            item: check.appcast!,
            platform: _windowsPlatform,
            send: httpClient.inner.send,
            skipBuild: rememberSkippedBuild,
          )
        : AndroidUpdateFlow(
            feed: check.androidFeed!,
            platform: _androidPlatform,
            send: httpClient.inner.send,
            isTv: PlatformDetector.isTV(),
            skipBuild: rememberSkippedBuild,
          );
    unawaited(showForkUpdateDialog(context, flow, isSamsung: isSamsung).whenComplete(flow.dispose));
    return ForkUpdateOutcome.shown;
  }

  final AppUpdatePlatform _androidPlatform = MethodChannelAppUpdatePlatform();
  final InstallerPlatform _windowsPlatform = ProcessInstallerPlatform();

  static Future<FeedResponse> _get(Uri uri) async {
    final response = await httpClient.get(
      uri.toString(),
      headers: uri.host == 'api.github.com' ? const {'Accept': 'application/vnd.github+json'} : null,
      timeout: const Duration(seconds: 20),
    );
    return (statusCode: response.statusCode, data: response.data);
  }
}
