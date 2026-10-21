import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/background_playback_policy.dart';

void main() {
  test('an Android phone playing VOD with the setting on keeps playing in the background', () {
    expect(
      shouldPlayVideoInBackground(
        isAndroid: true,
        isHandheld: true,
        isTv: false,
        isAutomotive: false,
        isLive: false,
        settingEnabled: true,
      ),
      isTrue,
    );
  });

  test('the setting gates the behavior off', () {
    expect(
      shouldPlayVideoInBackground(
        isAndroid: true,
        isHandheld: true,
        isTv: false,
        isAutomotive: false,
        isLive: false,
        settingEnabled: false,
      ),
      isFalse,
    );
  });

  test('Android TV keeps its own suspend-and-release policy, never this one', () {
    expect(
      shouldPlayVideoInBackground(
        isAndroid: true,
        isHandheld: false,
        isTv: true,
        isAutomotive: false,
        isLive: false,
        settingEnabled: true,
      ),
      isFalse,
    );
  });

  test('Android Automotive always pauses in the background (driver-distraction safety)', () {
    expect(
      shouldPlayVideoInBackground(
        isAndroid: true,
        isHandheld: true,
        isTv: false,
        isAutomotive: true,
        isLive: false,
        settingEnabled: true,
      ),
      isFalse,
    );
  });

  test('live TV keeps its tuner/transcode session and is excluded', () {
    expect(
      shouldPlayVideoInBackground(
        isAndroid: true,
        isHandheld: true,
        isTv: false,
        isAutomotive: false,
        isLive: true,
        settingEnabled: true,
      ),
      isFalse,
    );
  });

  test('non-Android platforms never use this flow', () {
    expect(
      shouldPlayVideoInBackground(
        isAndroid: false,
        isHandheld: true,
        isTv: false,
        isAutomotive: false,
        isLive: false,
        settingEnabled: true,
      ),
      isFalse,
    );
  });

  group('the Up Next countdown with the screen off', () {
    test('screen-off listening counts as someone there, so the countdown runs', () {
      expect(screenOffListenerPresent(backgroundAudioArmed: true, intentToPlay: true), isTrue);
    });

    test('a pause (lock screen, headset) brings the hold back', () {
      expect(screenOffListenerPresent(backgroundAudioArmed: true, intentToPlay: false), isFalse);
    });

    test('without background audio upstream holds the countdown as before', () {
      expect(screenOffListenerPresent(backgroundAudioArmed: false, intentToPlay: true), isFalse);
      expect(screenOffListenerPresent(backgroundAudioArmed: false, intentToPlay: false), isFalse);
    });
  });
}
