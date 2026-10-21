import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player_screen.dart';

/// Screen-off listening keeps the OS media session reporting `buffering`
/// (which keeps the media foreground service promoted) while the player is not
/// actively playing but is meant to be. A `paused` report demotes the service;
/// Android 12+ will not let a background app re-promote it, and about a minute
/// later the app's network is cut, so the next episode's stream dies. The end
/// of an item that rolls into the next one is part of playing, not a pause.
void main() {
  group('backgroundAudioHoldsSession', () {
    test('a finished item that is rolling into the next one keeps the session held', () {
      expect(
        backgroundAudioHoldsSession(armed: true, intentToPlay: true, completed: true, autoAdvancePending: true),
        isTrue,
      );
    });

    test('a finished item with nothing coming next reports paused', () {
      expect(
        backgroundAudioHoldsSession(armed: true, intentToPlay: true, completed: true, autoAdvancePending: false),
        isFalse,
      );
    });

    test('a mid-item stall the user did not ask for stays held', () {
      expect(
        backgroundAudioHoldsSession(armed: true, intentToPlay: true, completed: false, autoAdvancePending: false),
        isTrue,
      );
    });

    test('a user pause reports paused, even while an advance is pending', () {
      expect(
        backgroundAudioHoldsSession(armed: true, intentToPlay: false, completed: true, autoAdvancePending: true),
        isFalse,
      );
      expect(
        backgroundAudioHoldsSession(armed: true, intentToPlay: false, completed: false, autoAdvancePending: false),
        isFalse,
      );
    });

    test('without background audio nothing is held', () {
      expect(
        backgroundAudioHoldsSession(armed: false, intentToPlay: true, completed: true, autoAdvancePending: true),
        isFalse,
      );
    });
  });

  group('completionAutoAdvancePending', () {
    bool pending({
      bool autoPlayEnabled = true,
      bool hasNext = true,
      bool blocked = false,
      bool completionHandled = false,
      bool countdownRunning = false,
      bool loadingNext = false,
      bool stackedPartFollows = false,
    }) => completionAutoAdvancePending(
      autoPlayEnabled: autoPlayEnabled,
      hasNext: hasNext,
      blocked: blocked,
      completionHandled: completionHandled,
      countdownRunning: countdownRunning,
      loadingNext: loadingNext,
      stackedPartFollows: stackedPartFollows,
    );

    test('an end of file not yet handled, with auto-play on and a next item, is pending', () {
      expect(pending(), isTrue);
    });

    test('the Up Next countdown and the next item loading are pending', () {
      expect(pending(completionHandled: true, countdownRunning: true), isTrue);
      expect(pending(completionHandled: true, loadingNext: true), isTrue);
    });

    test('a handled end with no countdown and nothing loading (cancelled or failed) is not pending', () {
      expect(pending(completionHandled: true), isFalse);
    });

    test('auto-play off, no next item, or a blocker means no advance', () {
      expect(pending(autoPlayEnabled: false), isFalse);
      expect(pending(hasNext: false), isFalse);
      expect(pending(blocked: true), isFalse);
    });

    test("a multi-part item's next file is pending whatever the auto-play state", () {
      // The open file played out and the next part is opening: it is the same
      // item, so neither auto-play nor a next episode is involved.
      expect(
        pending(
          autoPlayEnabled: false,
          hasNext: false,
          blocked: true,
          completionHandled: true,
          stackedPartFollows: true,
        ),
        isTrue,
      );
    });
  });
}
