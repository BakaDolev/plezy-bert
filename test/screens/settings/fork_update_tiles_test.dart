import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/settings/fork_update_tiles.dart';
import 'package:plezy/services/fork_update/fork_updater.dart';
import 'package:plezy/services/fork_update/update_feed.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  tearDown(SettingsService.resetForTesting);

  Widget harness({required Future<ForkUpdateOutcome> Function() check}) => MaterialApp(
    theme: ThemeData(extensions: const [testMonoTokens]),
    home: Scaffold(body: ForkUpdateTiles(check: check)),
  );

  testWidgets('the beta switch moves this device to the beta channel', (tester) async {
    await tester.pumpWidget(harness(check: () async => ForkUpdateOutcome.upToDate));
    expect(forkUpdateChannel, UpdateChannel.stable);
    expect(find.text('Stable builds'), findsOneWidget);

    await tester.tap(find.text('Beta updates'));
    await tester.pumpAndSettle();

    expect(SettingsService.instance.read(forkUpdateBetaPref), isTrue);
    expect(forkUpdateChannel, UpdateChannel.beta);
    expect(find.text('Beta builds'), findsOneWidget);
  });

  testWidgets('the button runs a check and says what it found', (tester) async {
    var checks = 0;
    await tester.pumpWidget(
      harness(
        check: () async {
          checks++;
          return ForkUpdateOutcome.playing;
        },
      ),
    );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(checks, 1);
    expect(find.text('Stop playback to update'), findsOneWidget);
  });

  test('every outcome but an open window has a message', () {
    for (final outcome in ForkUpdateOutcome.values) {
      final message = forkUpdateMessage(outcome);
      expect(message == null, outcome == ForkUpdateOutcome.shown, reason: '$outcome');
    }
  });

  test("the version line is the fork's own version, never the build number or commit", () {
    expect(forkVersionText(version: '0.0.3'), '0.0.3 (beta)');
    expect(forkVersionText(version: '1.1.0'), '1.1.0');
    // No --dart-define in `flutter test`: a local build has no version of its own.
    expect(forkVersionText(), 'dev build');
  });
}
