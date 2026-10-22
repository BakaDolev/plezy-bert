/// What the fork's two updaters share (fork-only; never upstream): the steps
/// the update dialog shows, a checked download, and clearing what an earlier
/// update left behind. [AndroidUpdateFlow] and [WindowsUpdateFlow] fill in
/// how the file is checked and handed to the system's installer.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';

enum UpdateStep { offer, needsPermission, downloading, checking, failed, handedOver }

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);
  final String message;

  @override
  String toString() => 'UpdateDownloadException: $message';
}

class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
}

typedef HttpSend = Future<http.StreamedResponse> Function(http.BaseRequest request);

/// [url]'s file name when it is a plain one ending in [extension]; [fallback]
/// for anything unexpected.
String safeFileName(Uri url, String extension, String fallback) {
  final name = url.pathSegments.isEmpty ? '' : url.pathSegments.last;
  final plain = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && !name.startsWith('.');
  return plain && name.toLowerCase().endsWith(extension) ? name : fallback;
}

/// Removes what earlier updates left behind.
Future<void> purgeUpdates(Directory dir) async {
  if (!await dir.exists()) return;
  await for (final entry in dir.list()) {
    try {
      await entry.delete(recursive: true);
    } catch (e) {
      appLogger.d('Could not remove ${entry.path}', error: e);
    }
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

/// Streams [url] into [dir] as `<name>.tmp`, then keeps it under [name] only
/// if it is exactly [size] bytes (and matches [sha256] when given). Anything
/// else deletes the partial file and throws [UpdateDownloadException] (or
/// [UpdateDownloadCancelled]).
Future<File> downloadUpdateFile({
  required Uri url,
  required int size,
  String? sha256,
  required String name,
  required Directory dir,
  required HttpSend send,
  void Function(int received, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  await dir.create(recursive: true);
  final partial = File('${dir.path}${Platform.pathSeparator}$name.tmp');
  final target = File('${dir.path}${Platform.pathSeparator}$name');

  final response = await send(http.Request('GET', url));
  if (response.statusCode != 200) {
    unawaited(response.stream.drain<void>().catchError((_) {}));
    throw UpdateDownloadException('the download returned HTTP ${response.statusCode}');
  }

  final digest = _DigestSink();
  final hasher = crypto.sha256.startChunkedConversion(digest);
  final out = partial.openWrite();
  var received = 0;
  try {
    // A stalled connection fails instead of hanging the dialog.
    await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
      if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
      received += chunk.length;
      if (received > size) throw const UpdateDownloadException('the download is bigger than the release says');
      out.add(chunk);
      hasher.add(chunk);
      onProgress?.call(received, size);
    }
    if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
    await out.flush();
    await out.close();
    hasher.close();
    if (received != size) throw const UpdateDownloadException('the download is incomplete');
    if (sha256 != null && digest.value.toString() != sha256) {
      throw const UpdateDownloadException("the download doesn't match the release's checksum");
    }
  } catch (_) {
    await out.close().catchError((_) {});
    if (await partial.exists()) await partial.delete();
    rethrow;
  }
  if (await target.exists()) await target.delete();
  return partial.rename(target.path);
}

/// One offered update, from "Install" to the system's installer, for the
/// dialog to show.
abstract class ForkUpdateFlow extends ChangeNotifier {
  ForkUpdateFlow({required this.build, required this.version, required this.notes, required this.skipBuild});

  final int build;

  /// The fork version, e.g. "0.0.2".
  final String version;
  final String notes;
  final Future<void> Function(int build) skipBuild;

  UpdateStep step = UpdateStep.offer;

  /// 0..1 while downloading.
  double progress = 0;

  /// What to tell the user at [UpdateStep.needsPermission] or
  /// [UpdateStep.failed].
  String? message;

  /// A line for the offer, about what installing will do.
  String? get offerNote => null;

  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  Future<void> install() async {
    if (step == UpdateStep.downloading || step == UpdateStep.checking) return;
    _cancelled = false;
    try {
      await run();
    } on UpdateDownloadCancelled {
      go(UpdateStep.offer, null);
    } on UpdateDownloadException catch (e) {
      appLogger.w('Fork update download failed: ${e.message}');
      go(UpdateStep.failed, 'The update could not be downloaded: ${e.message}.');
    } catch (e, stackTrace) {
      appLogger.w('Fork update failed', error: e, stackTrace: stackTrace);
      go(UpdateStep.failed, 'The update could not be downloaded.');
    }
  }

  /// Gets the update to the system's installer; ends in [go] to the step it
  /// reached. Throwing [UpdateDownloadException] or [UpdateDownloadCancelled]
  /// is reported by [install].
  @protected
  Future<void> run();

  void cancel() => _cancelled = true;

  /// Opens the screen that lets Plezy install apps (Android).
  Future<void> openSettings() async {}

  Future<void> skip() => skipBuild(build);

  @protected
  void go(UpdateStep next, String? text) {
    step = next;
    message = text;
    notifyListeners();
  }

  @protected
  void reportProgress(int received, int total) {
    progress = received / total;
    notifyListeners();
  }
}
