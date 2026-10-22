import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/fork_update/update_gate.dart';
import 'package:plezy/services/music/music_playback_service.dart';

void main() {
  group('UpdateGate', () {
    // Injectable clock: tests advance `now` instead of sleeping.
    late DateTime now;
    late UpdateGate gate;

    setUp(() {
      now = DateTime(2026, 10, 21, 20);
      gate = UpdateGate(now: () => now);
    });

    test('the first main screen of the process is a fresh open, taken once', () {
      gate.noteMainScreenStart();
      expect(gate.takeFreshOpen(), isTrue);
      expect(gate.takeFreshOpen(), isFalse);
    });

    test('a main screen rebuilt for another profile is not a fresh open', () {
      gate.noteMainScreenStart();
      expect(gate.takeFreshOpen(), isTrue);
      gate.noteMainScreenStart();
      expect(gate.takeFreshOpen(), isFalse);
    });

    test('an open not taken yet waits for the next main screen (the profile picker was up)', () {
      gate.noteMainScreenStart();
      now = now.add(const Duration(seconds: 40));
      gate.noteMainScreenStart(); // the profile picked rebuilds the main screen
      expect(gate.takeFreshOpen(), isTrue);
    });

    test('coming back after a long time away is a fresh open', () {
      gate.noteMainScreenStart();
      expect(gate.takeFreshOpen(), isTrue);
      gate.noteBackAfterLongAway();
      expect(gate.takeFreshOpen(), isTrue);
      expect(gate.takeFreshOpen(), isFalse);
    });

    test('an open is stale once Plezy has been in use for a while', () {
      gate.noteMainScreenStart();
      now = now.add(const Duration(minutes: 10, seconds: 1));
      expect(gate.takeFreshOpen(), isFalse);
    });

    test('nothing is pending before any main screen', () {
      expect(gate.takeFreshOpen(), isFalse);
    });
  });

  group('isPlaybackActive', () {
    test('idle when nothing plays', () {
      for (final status in [null, MusicPlaybackStatus.idle, MusicPlaybackStatus.paused, MusicPlaybackStatus.error]) {
        expect(isPlaybackActive(videoPlayerOpen: false, musicStatus: status, pipActive: false), isFalse);
      }
    });

    test('an open video player counts, even paused', () {
      expect(isPlaybackActive(videoPlayerOpen: true, musicStatus: null, pipActive: false), isTrue);
    });

    test('music playing or starting counts', () {
      expect(
        isPlaybackActive(videoPlayerOpen: false, musicStatus: MusicPlaybackStatus.playing, pipActive: false),
        isTrue,
      );
      expect(
        isPlaybackActive(videoPlayerOpen: false, musicStatus: MusicPlaybackStatus.loading, pipActive: false),
        isTrue,
      );
    });

    test('picture-in-picture counts', () {
      expect(isPlaybackActive(videoPlayerOpen: false, musicStatus: null, pipActive: true), isTrue);
    });
  });
}
