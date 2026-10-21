import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player_screen.dart';

/// When the app's network is cut during screen-off listening, mpv's reconnect
/// loop backs off for minutes (up to `reconnect_delay_max`) and a transcode
/// session is reaped server-side, so after unlocking the player sat stalled
/// until its next scheduled retry. On resume the stream is rebuilt — but only
/// when it is actually dead: a fault mpv recovered from on its own has fed the
/// cache since, and rebuilding it would just interrupt the audio.
void main() {
  const faultCacheEnd = Duration(minutes: 12, seconds: 31);

  test('no transport fault while backgrounded: no rebuild', () {
    expect(
      shouldRebuildStreamOnResume(
        cacheEndAtBackgroundFault: null,
        cacheEnd: faultCacheEnd,
        itemFinished: false,
        stoppedByServer: false,
      ),
      isFalse,
    );
  });

  test('a fault with no media arriving since rebuilds the stream', () {
    expect(
      shouldRebuildStreamOnResume(
        cacheEndAtBackgroundFault: faultCacheEnd,
        cacheEnd: faultCacheEnd,
        itemFinished: false,
        stoppedByServer: false,
      ),
      isTrue,
    );
  });

  test('a fault the stream recovered from (cache grew since) is left alone', () {
    expect(
      shouldRebuildStreamOnResume(
        cacheEndAtBackgroundFault: faultCacheEnd,
        cacheEnd: faultCacheEnd + const Duration(seconds: 30),
        itemFinished: false,
        stoppedByServer: false,
      ),
      isFalse,
    );
  });

  test('a cache end behind the fault point (cache dropped) still rebuilds', () {
    expect(
      shouldRebuildStreamOnResume(
        cacheEndAtBackgroundFault: faultCacheEnd,
        cacheEnd: Duration.zero,
        itemFinished: false,
        stoppedByServer: false,
      ),
      isTrue,
    );
  });

  test('a finished item is not rebuilt: the Up Next countdown or the viewer decides what plays next', () {
    expect(
      shouldRebuildStreamOnResume(
        cacheEndAtBackgroundFault: faultCacheEnd,
        cacheEnd: faultCacheEnd,
        itemFinished: true,
        stoppedByServer: false,
      ),
      isFalse,
    );
  });

  test('a stream stopped from the server dashboard stays stopped', () {
    expect(
      shouldRebuildStreamOnResume(
        cacheEndAtBackgroundFault: faultCacheEnd,
        cacheEnd: faultCacheEnd,
        itemFinished: false,
        stoppedByServer: true,
      ),
      isFalse,
    );
  });
}
