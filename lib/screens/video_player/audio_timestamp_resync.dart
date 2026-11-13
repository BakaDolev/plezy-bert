import 'dart:async';

import '../../mpv/mpv.dart';

/// Whether [log] is mpv restarting audio because the file's audio timestamps
/// jumped. A damaged file does this: its timestamps leap ahead and back, mpv
/// resets audio each time, and once the damage has passed picture and sound
/// stay apart until something seeks.
bool isAudioTimestampResetLog(PlayerLog log) =>
    log.prefix == 'cplayer' && log.text.contains('Reset playback due to audio timestamp reset');

/// Re-syncs picture and sound once a burst of audio timestamp resets is over.
///
/// Every reset restarts a [quietPeriod] timer, so [onResync] runs once, after
/// the damaged stretch has stopped logging, rather than in the middle of it.
/// At most [maxPerWindow] re-syncs run per [window], so a file broken
/// throughout cannot turn this into a seek loop. Only the timer bookkeeping
/// lives here so it is testable with `fakeAsync`; the caller owns the seek.
class AudioTimestampResync {
  AudioTimestampResync({
    required this.onResync,
    this.quietPeriod = const Duration(milliseconds: 1500),
    this.maxPerWindow = 3,
    this.window = const Duration(seconds: 60),
  });

  final void Function() onResync;
  final Duration quietPeriod;
  final int maxPerWindow;
  final Duration window;

  Timer? _pending;
  final List<Timer> _budget = [];

  /// mpv logged an audio timestamp reset.
  void onReset() {
    if (_budget.length >= maxPerWindow) return;
    _pending?.cancel();
    _pending = Timer(quietPeriod, _fire);
  }

  /// A new open, an exit or dispose: drop a pending re-sync and the budget.
  void cancel() {
    _pending?.cancel();
    _pending = null;
    for (final timer in _budget) {
      timer.cancel();
    }
    _budget.clear();
  }

  void _fire() {
    _pending = null;
    late final Timer refill;
    refill = Timer(window, () => _budget.remove(refill));
    _budget.add(refill);
    onResync();
  }
}
