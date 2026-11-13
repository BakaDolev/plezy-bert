import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:plezy/widgets/video_controls/sheets/track_sheet.dart';

import '../test_helpers/theme.dart';

/// Opening the subtitle sheet with a TV remote (Trello #105): the list must
/// open from "Off" whenever the current subtitle fits, focus must sit on the
/// current subtitle, and one press moves one row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  final subtitles = [for (var i = 1; i <= 10; i++) SubtitleTrack(id: 's$i', title: 'Subtitle $i')];

  late BuildContext hostContext;

  Future<void> openSubtitleSheet(WidgetTester tester, {required SubtitleTrack selected, double height = 720}) async {
    final player = _FakePlayer(
      tracks: Tracks(subtitle: subtitles),
      track: TrackSelection(subtitle: selected),
    );
    await tester.binding.setSurfaceSize(Size(1280, height));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      InputModeTracker(
        child: MaterialApp(
          theme: ThemeData(extensions: const [testMonoTokens]),
          home: OverlaySheetHost(
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  hostContext = context;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // A remote press is what opens the sheet on a TV.
    InputModeTracker.reportNonPointerInput();
    await tester.pump();

    unawaited(
      OverlaySheetController.of(hostContext).show<void>(
        builder: (_) => TrackSheet(
          player: player,
          trackControlsState: const TrackControlsState(
            ratingKey: '123',
            serverId: 'plex-server',
            subtitleSearchSupported: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The visible text of the row that holds focus.
  String? focusedRowText() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return null;
    String? text;
    focusContext.visitChildElements((element) {
      void visit(Element e) {
        if (text != null) return;
        final widget = e.widget;
        if (widget is Text && widget.data != null) {
          text = widget.data;
          return;
        }
        e.visitChildElements(visit);
      }

      visit(element);
    });
    return text;
  }

  bool isOnScreen(WidgetTester tester, String label) {
    final finder = find.text(label);
    if (finder.evaluate().isEmpty) return false;
    final rect = tester.getRect(finder.first);
    final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
    final viewport = tester.getRect(find.byType(ListView).first);
    return screen.contains(rect.center) && viewport.contains(rect.center);
  }

  testWidgets('a subtitle a few rows down: list opens from Off and focus is on it', (tester) async {
    await openSubtitleSheet(tester, selected: subtitles[2]);

    expect(focusedRowText(), 'Subtitle 3', reason: 'focus starts on the current subtitle');
    expect(isOnScreen(tester, 'Subtitle 3'), isTrue, reason: 'the current subtitle is visible');
    expect(isOnScreen(tester, 'Off'), isTrue, reason: '"Off" stays in view when the current subtitle fits');
  });

  testWidgets('a subtitle further down than fits: focused, visible, and as many rows above as fit', (tester) async {
    await openSubtitleSheet(tester, selected: subtitles[7]);

    expect(focusedRowText(), 'Subtitle 8');
    expect(isOnScreen(tester, 'Subtitle 8'), isTrue);
    expect(isOnScreen(tester, 'Subtitle 9'), isFalse, reason: 'the list moved only as far as needed');
  });

  testWidgets('Up from the current subtitle moves one row up', (tester) async {
    await openSubtitleSheet(tester, selected: subtitles[7]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    expect(focusedRowText(), 'Subtitle 7');
  });

  testWidgets('subtitles off: focus starts on Off', (tester) async {
    await openSubtitleSheet(tester, selected: SubtitleTrack.off);

    expect(focusedRowText(), 'Off');
    expect(isOnScreen(tester, 'Off'), isTrue);
  });

  testWidgets('a short screen still shows and focuses the current subtitle', (tester) async {
    await openSubtitleSheet(tester, selected: subtitles[9], height: 420);

    expect(focusedRowText(), 'Subtitle 10');
    expect(isOnScreen(tester, 'Subtitle 10'), isTrue);
  });
}

class _FakePlayer implements Player {
  _FakePlayer({required Tracks tracks, required TrackSelection track})
    : _state = PlayerState(tracks: tracks, track: track),
      _streams = PlayerStreams(
        playing: const Stream<bool>.empty(),
        completed: const Stream<bool>.empty(),
        buffering: const Stream<bool>.empty(),
        position: const Stream<Duration>.empty(),
        duration: const Stream<Duration>.empty(),
        seekable: const Stream<bool>.empty(),
        buffer: const Stream<Duration>.empty(),
        volume: const Stream<double>.empty(),
        rate: const Stream<double>.empty(),
        tracks: const Stream<Tracks>.empty(),
        track: const Stream<TrackSelection>.empty(),
        log: const Stream<PlayerLog>.empty(),
        error: const Stream<PlayerError>.empty(),
        audioDevice: const Stream<AudioDevice>.empty(),
        audioDevices: const Stream<List<AudioDevice>>.empty(),
        bufferRanges: const Stream<List<BufferRange>>.empty(),
        playbackRestart: const Stream<void>.empty(),
        backendSwitched: const Stream<void>.empty(),
      );

  final PlayerState _state;
  final PlayerStreams _streams;

  @override
  bool get supportsSecondarySubtitles => false;

  @override
  PlayerState get state => _state;

  @override
  PlayerStreams get streams => _streams;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
