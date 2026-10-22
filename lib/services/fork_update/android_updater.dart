/// The fork's Android updater (fork-only; never upstream).
///
/// Downloads the APK for this device's CPU type from the release feed, checks
/// its size and SHA-256, and hands it to Android's own installer through the
/// `com.plezy/app_update` channel (AppUpdateChannel.kt). Android then asks
/// the user and updates in place: same package, same signing key, higher
/// version code, so sign-in and settings stay.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../settings_service.dart';
import 'update_feed.dart';
import 'update_flow.dart';

/// The build the user chose to skip; 0 for none. A manual check from About
/// still offers it.
const forkUpdateSkippedBuildPref = IntPref('fork_update_skipped_build');

/// Android's side of the updater (AppUpdateChannel.kt).
abstract class AppUpdatePlatform {
  /// Whether this process runs 64-bit (a TV may run the 32-bit build on a
  /// 64-bit CPU, and must keep it).
  Future<bool> is64Bit();

  /// The only folder [installApk] accepts.
  Future<String> updatesDir();
  Future<int> freeBytes();

  /// Whether Plezy may install apps.
  Future<bool> canInstall();

  /// Opens the screen that lets Plezy install apps (or the closest one);
  /// which one opened, or null.
  Future<String?> openInstallSettings();
  Future<bool> installApk(String path);
  Future<bool> isSamsung();
}

class MethodChannelAppUpdatePlatform implements AppUpdatePlatform {
  static const _channel = MethodChannel('com.plezy/app_update');

  @override
  Future<bool> is64Bit() async => await _channel.invokeMethod<bool>('is64Bit') ?? true;
  @override
  Future<String> updatesDir() async => (await _channel.invokeMethod<String>('updatesDir'))!;
  @override
  Future<int> freeBytes() async => await _channel.invokeMethod<int>('freeBytes') ?? 0;
  @override
  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;
  @override
  Future<String?> openInstallSettings() => _channel.invokeMethod<String>('openInstallSettings');
  @override
  Future<bool> installApk(String path) async =>
      await _channel.invokeMethod<bool>('installApk', {'path': path}) ?? false;
  @override
  Future<bool> isSamsung() async => await _channel.invokeMethod<bool>('isSamsung') ?? false;
}

/// The feed's APK for this process: arm64-v8a when it runs 64-bit,
/// armeabi-v7a otherwise.
ApkAsset? pickApk(AndroidFeed feed, {required bool is64Bit}) => feed.apks[is64Bit ? 'arm64-v8a' : 'armeabi-v7a'];

/// The APK's file name, from its URL; `update.apk` for anything unexpected.
String apkFileName(ApkAsset apk) => safeFileName(apk.url, '.apk', 'update.apk');

/// Downloads [apk] into [dir], checked against its size and SHA-256.
Future<File> downloadApk(
  ApkAsset apk, {
  required Directory dir,
  required HttpSend send,
  void Function(int received, int total)? onProgress,
  bool Function()? isCancelled,
}) => downloadUpdateFile(
  url: apk.url,
  size: apk.size,
  sha256: apk.sha256,
  name: apkFileName(apk),
  dir: dir,
  send: send,
  onProgress: onProgress,
  isCancelled: isCancelled,
);

class AndroidUpdateFlow extends ForkUpdateFlow {
  AndroidUpdateFlow({
    required this.feed,
    required this.platform,
    required this.send,
    required this.isTv,
    required super.skipBuild,
  }) : super(build: feed.build, version: feed.version, notes: feed.notes);

  final AndroidFeed feed;
  final AppUpdatePlatform platform;
  final HttpSend send;
  final bool isTv;

  @override
  Future<void> run() async {
    if (!await platform.canInstall()) {
      go(UpdateStep.needsPermission, _permissionHelp());
      return;
    }
    final apk = pickApk(feed, is64Bit: await platform.is64Bit());
    if (apk == null) {
      go(UpdateStep.failed, 'This release has no build for this device.');
      return;
    }
    final dir = Directory(await platform.updatesDir());
    // The installer unpacks next to the download, so leave it room.
    if (await platform.freeBytes() < apk.size * 3) {
      go(UpdateStep.failed, 'Not enough free space: the update needs about ${_megabytes(apk.size * 3)} MB.');
      return;
    }
    progress = 0;
    go(UpdateStep.downloading, null);
    final file = await downloadApk(
      apk,
      dir: dir,
      send: send,
      isCancelled: () => isCancelled,
      onProgress: reportProgress,
    );
    if (!await platform.installApk(file.path)) {
      go(UpdateStep.failed, "Android's installer didn't open.");
      return;
    }
    go(UpdateStep.handedOver, null);
  }

  @override
  Future<void> openSettings() async {
    final opened = await platform.openInstallSettings();
    if (opened == null) message = '${message ?? _permissionHelp()}\n\nThe settings screen could not be opened here.';
    notifyListeners();
  }

  String _permissionHelp() => isTv
      ? 'Plezy needs permission to install updates. On the TV: Settings → Apps → Security & restrictions → '
            'Unknown sources → turn on Plezy. Then come back and choose Install again.'
      : 'Plezy needs permission to install updates. Choose Open settings, turn on "Allow from this source", '
            'then come back and choose Install again.';

  static int _megabytes(int bytes) => (bytes / (1024 * 1024)).ceil();
}

/// Writes the skipped build (see [forkUpdateSkippedBuildPref]).
Future<void> rememberSkippedBuild(int build) => SettingsService.instance.write(forkUpdateSkippedBuildPref, build);
