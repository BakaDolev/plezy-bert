import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/screens/video_player/audio_timestamp_resync.dart';

void main() {
  group('isAudioTimestampResetLog', () {
    test("matches mpv's reset line", () {
      expect(
        isAudioTimestampResetLog(
          const PlayerLog(
            level: PlayerLogLevel.warn,
            prefix: 'cplayer',
            text: 'Reset playback due to audio timestamp reset.',
          ),
        ),
        isTrue,
      );
    });

    test('ignores the desync advice and other lines', () {
      expect(
        isAudioTimestampResetLog(
          const PlayerLog(
            level: PlayerLogLevel.warn,
            prefix: 'cplayer',
            text: 'Audio/Video desynchronisation detected! Possible reasons include too slow',
          ),
        ),
        isFalse,
      );
      expect(
        isAudioTimestampResetLog(
          const PlayerLog(level: PlayerLogLevel.warn, prefix: 'ad', text: 'Invalid audio PTS: 50.2 -> 59.8'),
        ),
        isFalse,
      );
    });
  });

  group('AudioTimestampResync', () {
    test('re-syncs once, after the burst has been quiet for the quiet period', () {
      fakeAsync((async) {
        var resyncs = 0;
        final resync = AudioTimestampResync(onResync: () => resyncs++);

        // A damaged spot logs several resets in quick succession.
        for (var i = 0; i < 4; i++) {
          resync.onReset();
          async.elapse(const Duration(milliseconds: 400));
        }
        expect(resyncs, 0, reason: 'still inside the burst');

        async.elapse(const Duration(milliseconds: 1500));
        expect(resyncs, 1, reason: 'one seek once the resets stop');

        async.elapse(const Duration(seconds: 10));
        expect(resyncs, 1);
      });
    });

    test('caps re-syncs per window so a badly broken file cannot loop', () {
      fakeAsync((async) {
        var resyncs = 0;
        final resync = AudioTimestampResync(onResync: () => resyncs++, maxPerWindow: 3);

        for (var i = 0; i < 6; i++) {
          resync.onReset();
          async.elapse(const Duration(seconds: 2));
        }
        expect(resyncs, 3);

        async.elapse(const Duration(seconds: 60));
        resync.onReset();
        async.elapse(const Duration(seconds: 2));
        expect(resyncs, 4, reason: 'the budget refills after the window');
      });
    });

    test('cancel drops a pending re-sync', () {
      fakeAsync((async) {
        var resyncs = 0;
        final resync = AudioTimestampResync(onResync: () => resyncs++);

        resync.onReset();
        resync.cancel();
        async.elapse(const Duration(seconds: 5));

        expect(resyncs, 0);
      });
    });
  });
}
