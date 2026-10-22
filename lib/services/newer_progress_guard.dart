import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';

/// Notices when another device moved an item's resume point past where this
/// paused device left it, so this one stops writing its older spot back.
///
/// A paused player keeps reporting its position (the heartbeat that holds the
/// server session open, #1520) and reports once more when it closes, and the
/// server keeps whichever report came last. Left paused on one device while
/// the viewer watches on another, it would drag the resume point back every
/// ten seconds and again on close.
///
/// "Moved by another device" is read narrowly, because the server's resume
/// point lags, keeps an older one a short watch didn't replace, and follows
/// this device's own seeks: it must have changed since the first look while
/// paused, and be ahead of anything this device ever reported.
class NewerProgressGuard {
  NewerProgressGuard({required this.readResumePoint, this.tolerance = const Duration(seconds: 5)});

  /// The item's resume point on the server right now; null when it has none.
  final Future<Duration?> Function() readResumePoint;

  /// Drift that never counts as another device.
  final Duration tolerance;

  /// Where another device left the item, while it is ahead of this device.
  final ValueNotifier<Duration?> overtakenAt = ValueNotifier<Duration?>(null);

  Duration? _furthestReported;
  Duration? _firstSeen;
  bool _looking = false;

  bool get isOvertaken => overtakenAt.value != null;

  /// A report from this device reached the server at [position].
  void noteReported(Duration position) {
    final furthest = _furthestReported;
    if (furthest == null || position > furthest) _furthestReported = position;
  }

  /// Before a paused heartbeat: whether it may go out. False once overtaken
  /// (the look keeps [overtakenAt] on the newest spot), and while an earlier
  /// look is still out, so a heartbeat never races the answer.
  Future<bool> mayReportPaused() async {
    if (_looking) return false;
    if (isOvertaken) {
      await _refresh();
      return false;
    }
    final furthest = _furthestReported;
    if (furthest == null) return true;
    final server = await _read();
    if (server == null) return true;
    final firstSeen = _firstSeen ??= server;
    if (server != firstSeen && server > furthest + tolerance) {
      appLogger.i('Resume point moved to $server on another device; this one paused at or before $furthest');
      overtakenAt.value = server;
      return false;
    }
    return true;
  }

  /// Where this device's closing report may land: the newest spot seen once
  /// overtaken (looked up again, since the other device may have gone on), or
  /// null for its own spot.
  Future<Duration?> closingSpot() async {
    if (!isOvertaken) return null;
    await _refresh();
    return overtakenAt.value;
  }

  /// The viewer chose to play on here (from the newer spot or their own).
  void release() {
    overtakenAt.value = null;
    _firstSeen = null;
  }

  /// This device's session closed at [ownSpot] and is reopening (a TV
  /// restored from the background): whether another device went further
  /// meanwhile.
  Future<bool> recheckAfterClose(Duration ownSpot) async {
    noteReported(ownSpot);
    _firstSeen = ownSpot;
    final server = await _read();
    final furthest = _furthestReported!;
    if (server != null && server != ownSpot && server > furthest + tolerance) {
      appLogger.i('Resume point moved to $server on another device while this one was away at $ownSpot');
      overtakenAt.value = server;
    }
    return isOvertaken;
  }

  Future<void> _refresh() async {
    final server = await _read();
    final current = overtakenAt.value;
    if (server != null && current != null && server > current) overtakenAt.value = server;
  }

  Future<Duration?> _read() async {
    _looking = true;
    try {
      return await readResumePoint();
    } catch (e) {
      appLogger.d('Could not read the resume point', error: e);
      return null;
    } finally {
      _looking = false;
    }
  }

  void dispose() => overtakenAt.dispose();
}
