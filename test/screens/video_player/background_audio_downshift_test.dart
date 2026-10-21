import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/screens/video_player_screen.dart';

/// Screen-off listening on an Android phone drops to a low-bitrate stream so
/// the demuxer cache outlasts Wi-Fi/Doze network gaps. The swap waits for the
/// next item: the next episode loads fresh anyway, whereas a mid-episode reload
/// silenced the audio for ~3 s.
void main() {
  const cap = TranscodeQualityPreset.p240_320;

  test('a pending downshift loads the next item at the background cap', () {
    expect(
      backgroundAudioPresetForNextItem(selected: TranscodeQualityPreset.original, downshiftPending: true, cap: cap),
      cap,
    );
    expect(
      backgroundAudioPresetForNextItem(selected: TranscodeQualityPreset.p1080_8mbps, downshiftPending: true, cap: cap),
      cap,
    );
  });

  test('without a pending downshift the next item keeps the selected quality', () {
    expect(
      backgroundAudioPresetForNextItem(selected: TranscodeQualityPreset.original, downshiftPending: false, cap: cap),
      TranscodeQualityPreset.original,
    );
  });

  test('a selection already at or below the cap is kept (nothing to gain)', () {
    expect(backgroundAudioPresetForNextItem(selected: cap, downshiftPending: true, cap: cap), cap);
    expect(
      backgroundAudioPresetForNextItem(
        selected: TranscodeQualityPreset.p240_320,
        downshiftPending: true,
        cap: TranscodeQualityPreset.p320_720,
      ),
      TranscodeQualityPreset.p240_320,
    );
  });
}
