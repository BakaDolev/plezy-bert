/// When the fork's updater may appear on its own (fork-only; never upstream).
///
/// Only when Plezy is opened fresh: the first time the main screen comes up
/// in a process, or when Plezy comes back to the front after
/// [kUpdateAwayThreshold] in the background (TV launchers keep the process
/// alive for days, so a cold start alone could mean a TV never checks). And
/// never while something plays. The About screen's button is the other way in.
library;

import '../music/music_playback_service.dart';

/// How long Plezy must have been in the background for its return to count as
/// opening it fresh.
const Duration kUpdateAwayThreshold = Duration(hours: 1);

/// How long after a fresh open the check waits, so it doesn't race the
/// startup work or a title the user picks straight away.
const Duration kUpdateSettleDelay = Duration(seconds: 1);

class UpdateGate {
  UpdateGate({DateTime Function()? now, this.freshFor = const Duration(minutes: 10)}) : _now = now ?? DateTime.now;

  /// One per process: the main screen is rebuilt for every profile, the gate
  /// must not be.
  static final UpdateGate instance = UpdateGate();

  /// How long an open stays fresh while it waits to be taken (the profile
  /// picker can hold it up).
  final Duration freshFor;
  final DateTime Function() _now;

  bool _mainScreenSeen = false;
  DateTime? _openedAt;

  /// The first main screen of the process is a fresh open. Later ones (a
  /// profile switch rebuilds it) only pick up an open not taken yet.
  void noteMainScreenStart() {
    if (_mainScreenSeen) return;
    _mainScreenSeen = true;
    _openedAt = _now();
  }

  /// Plezy came back to the front after [kUpdateAwayThreshold] away.
  void noteBackAfterLongAway() => _openedAt = _now();

  /// True once per fresh open, while it is still fresh.
  bool takeFreshOpen() {
    final openedAt = _openedAt;
    _openedAt = null;
    return openedAt != null && _now().difference(openedAt) <= freshFor;
  }
}

/// Whether an update must wait: a video player is open (paused counts: the
/// user is mid-episode), music is playing or starting, or picture-in-picture
/// is up.
bool isPlaybackActive({
  required bool videoPlayerOpen,
  required MusicPlaybackStatus? musicStatus,
  required bool pipActive,
}) =>
    videoPlayerOpen ||
    pipActive ||
    musicStatus == MusicPlaybackStatus.playing ||
    musicStatus == MusicPlaybackStatus.loading;
