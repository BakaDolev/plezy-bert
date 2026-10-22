import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/widgets/newer_progress_dialog.dart';

import '../test_helpers/theme.dart';

void main() {
  // A record, not the future itself: an async function returning a future
  // would wait for the dialog to close.
  Future<({Future<bool?> answer})> show(WidgetTester tester) async {
    late Future<bool?> answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => answer = showNewerProgressDialog(
              context,
              newer: const Duration(minutes: 45, seconds: 3),
              own: const Duration(minutes: 28, seconds: 31),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (answer: answer);
  }

  testWidgets('names both spots, and Continue is the one in focus', (tester) async {
    await show(tester);
    expect(find.text('You watched further on another device. Continue from 45:03, or stay at 28:31?'), findsOneWidget);
    // The primary focus itself, not just a scope around it (a TV remote lands here).
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      find.descendant(of: find.byWidget(focused!.widget), matching: find.text('Continue from 45:03')),
      findsOneWidget,
    );
    expect(find.descendant(of: find.byWidget(focused.widget), matching: find.text('Stay at 28:31')), findsNothing);
  });

  testWidgets('Continue answers true, Stay false, dismissing null', (tester) async {
    var answer = (await show(tester)).answer;
    await tester.tap(find.text('Continue from 45:03'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);

    answer = (await show(tester)).answer;
    await tester.tap(find.text('Stay at 28:31'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);

    answer = (await show(tester)).answer;
    await tester.tapAt(const Offset(5, 5)); // the barrier
    await tester.pumpAndSettle();
    expect(await answer, isNull);
  });

  group('a paused player in the background, when its time is up', () {
    PausedAwayStep step({
      AppLifecycleState state = AppLifecycleState.hidden,
      bool playing = false,
      bool pip = false,
      bool watchTogether = false,
    }) => pausedAwayStep(lifecycleState: state, playing: playing, pip: pip, watchTogether: watchTogether);

    test('closes when still away and paused', () {
      expect(step(), PausedAwayStep.close);
      expect(step(state: AppLifecycleState.paused), PausedAwayStep.close);
    });

    test('does nothing once back in front', () {
      expect(step(state: AppLifecycleState.resumed), PausedAwayStep.nothing);
      expect(step(state: AppLifecycleState.inactive), PausedAwayStep.nothing);
    });

    test('looks again later while still in use', () {
      expect(step(playing: true), PausedAwayStep.lookAgainLater);
      expect(step(pip: true), PausedAwayStep.lookAgainLater);
      expect(step(watchTogether: true), PausedAwayStep.lookAgainLater);
    });
  });
}
