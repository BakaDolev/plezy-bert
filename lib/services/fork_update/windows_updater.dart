/// The fork's Windows updater (fork-only; never upstream).
///
/// Downloads the installer the appcast names, checks its size and our EdDSA
/// signature ([kForkUpdatePublicKey]; its private half signs every release),
/// then runs it silently and closes Plezy. The installer opens Plezy again
/// when it is done, so one "Install" is all it takes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';
import '../app_exit_service.dart';
import 'update_feed.dart';
import 'update_flow.dart';

/// The public half of the fork's update key (also in windows/runner/Runner.rc).
const String kForkUpdatePublicKey = '6JjDPpNE2cJQnuGF3Miw8PlEdLwMAp8Q8tly/CaVK4g=';

/// No wizard, no questions, no restart of Windows. The installer closes what
/// is left of Plezy and opens it again at the end.
const List<String> kInstallerArguments = ['/SILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NORESTART'];

/// Windows' side of the updater.
abstract class InstallerPlatform {
  /// Where downloads wait for the installer.
  Future<String> updatesDir();

  /// Starts the installer on its own; false when it didn't start.
  Future<bool> start(String path);

  /// Closes Plezy so the installer can replace it.
  Future<void> exitForInstaller();
}

class ProcessInstallerPlatform implements InstallerPlatform {
  @override
  Future<String> updatesDir() async =>
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}PlezyFork-update';

  @override
  Future<bool> start(String path) async {
    try {
      await Process.start(path, kInstallerArguments, mode: ProcessStartMode.detached);
      return true;
    } catch (e, stackTrace) {
      appLogger.w('Fork update: the installer did not start', error: e, stackTrace: stackTrace);
      return false;
    }
  }

  @override
  Future<void> exitForInstaller() => AppExitService.requestGracefulExit();
}

/// Whether [signature] (base64) is [publicKey]'s EdDSA signature of [data].
Future<bool> verifyUpdateSignature(Uint8List data, String signature, {String publicKey = kForkUpdatePublicKey}) async {
  try {
    final sig = base64.decode(signature);
    final key = base64.decode(publicKey);
    if (sig.length != 64 || key.length != 32) return false;
    return await Ed25519().verify(
      data,
      signature: Signature(sig, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
    );
  } on FormatException {
    return false;
  }
}

/// Hashing ~60 MB in Dart takes a moment, so it runs off the UI thread. A
/// top-level function: a closure made inside the flow would carry the flow
/// (and its listeners) to the other isolate, which can't be sent.
Future<bool> _verifyInBackground(Uint8List data, String signature, String publicKey) =>
    Isolate.run(() => verifyUpdateSignature(data, signature, publicKey: publicKey));

class WindowsUpdateFlow extends ForkUpdateFlow {
  WindowsUpdateFlow({
    required this.item,
    required this.platform,
    required this.send,
    required super.skipBuild,
    this.publicKey = kForkUpdatePublicKey,
  }) : super(build: item.build, version: item.version.split('+').first, notes: item.notes ?? '');

  final AppcastItem item;
  final InstallerPlatform platform;
  final HttpSend send;
  final String publicKey;

  @override
  String get offerNote => 'Plezy closes while it installs and opens again by itself.';

  @override
  Future<void> run() async {
    final url = item.installerUrl, size = item.installerSize, signature = item.edSignature;
    if (url == null || size == null || signature == null) {
      go(UpdateStep.failed, 'This release has no installer for Windows.');
      return;
    }
    final dir = Directory(await platform.updatesDir());
    progress = 0;
    go(UpdateStep.downloading, null);
    final file = await downloadUpdateFile(
      url: url,
      size: size,
      name: safeFileName(url, '.exe', 'PlezyFork-update.exe'),
      dir: dir,
      send: send,
      isCancelled: () => isCancelled,
      onProgress: reportProgress,
    );
    go(UpdateStep.checking, null);
    final genuine = await _verifyInBackground(await file.readAsBytes(), signature, publicKey);
    if (!genuine) {
      await file.delete().catchError((_) => file);
      appLogger.w('Fork update: the installer failed its signature check');
      go(UpdateStep.failed, "The download isn't signed with the fork's key, so it was not installed.");
      return;
    }
    if (!await platform.start(file.path)) {
      go(UpdateStep.failed, "The installer didn't start.");
      return;
    }
    appLogger.i('Fork update: installer started, closing Plezy');
    go(UpdateStep.handedOver, null);
    unawaited(platform.exitForInstaller());
  }
}
