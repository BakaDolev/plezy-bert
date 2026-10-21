import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// An in-place episode swap while the app is hidden (screen-off listening)
/// gets no frame, so the controls never see the new item through
/// didUpdateWidget until the screen is back. The skip markers must follow the
/// screen's current item anyway: the outgoing episode's intro window must not
/// fire on the incoming one, and the incoming episode's own intro must skip.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const serverId = 'srv';
  final outgoingIntro = MediaMarker(id: 1, type: 'intro', startTimeOffset: 10000, endTimeOffset: 45000);
  // The incoming episode's intro, as the API cache holds it.
  const incomingIntroStartMs = 60000;
  const incomingIntroEndMs = 90000;

  late _PositionPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late MediaItem outgoing;
  late MediaItem incoming;
  late ValueNotifier<MediaItem> currentItem;
  late List<Duration> seeks;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.skipIntroMode, SkipMarkerMode.auto);
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    // The desktop chrome reads window state; real async below lets it resolve.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _windowChannel,
      (call) async => call.method.startsWith('is') ? false : null,
    );

    database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    player = _PositionPlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
    outgoing = testMediaItem(id: 'ep-1', serverId: serverId);
    incoming = testMediaItem(id: 'ep-2', serverId: serverId);
    currentItem = ValueNotifier<MediaItem>(outgoing);
    seeks = [];
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_windowChannel, null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    currentItem.dispose();
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await player.close();
    await database.close();
  });

  Widget shell(Widget child) => InputModeTracker(
    child: MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: database),
        ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
        ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows, extensions: const [testMonoTokens]),
        home: Scaffold(body: SizedBox(width: 1280, height: 720, child: child)),
      ),
    ),
  );

  Widget controls({required MediaItem metadata}) => PlexVideoControls(
    player: player,
    volumeController: volume,
    metadata: metadata,
    currentItem: currentItem,
    initialMarkers: [outgoingIntro],
    toastController: toast,
    chromeController: chrome,
    canNavigateMediaItems: false,
    onSeekRequested: (position) async => seeks.add(position),
  );

  /// Mounts the controls on the outgoing episode, then swaps the screen's
  /// current item WITHOUT rebuilding the controls — the parent still passes
  /// the outgoing metadata, as it does until the hidden app gets a frame.
  Future<void> swapWhileHidden(WidgetTester tester) async {
    await tester.runAsync(() async {
      await PlexApiCache.instance.put(ServerId(serverId), '/library/metadata/${incoming.id}', {
        'MediaContainer': {
          'Metadata': [
            {
              'ratingKey': incoming.id,
              'type': 'movie',
              'Marker': [
                {
                  'id': 2,
                  'type': 'intro',
                  'startTimeOffset': incomingIntroStartMs,
                  'endTimeOffset': incomingIntroEndMs,
                },
              ],
            },
          ],
        },
      });
    });
    await tester.pumpWidget(shell(controls(metadata: outgoing)));
    await tester.pump();

    player.moveTo(Duration.zero);
    await tester.runAsync(() async {
      currentItem.value = incoming;
      // The incoming item's extras come from the API cache (an isolate decode).
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(shell(const SizedBox.expand()));
    await tester.pump();
    chrome.cancelAutoHide();
  }

  testWidgets('the outgoing episode\'s intro window does not fire on the incoming one', (tester) async {
    await swapWhileHidden(tester);

    // Inside the outgoing intro (10–45 s), outside the incoming one (60–90 s).
    player.moveTo(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 6));

    expect(seeks, isEmpty, reason: 'the incoming episode has no intro at 20 s');
    await finish(tester);
  });

  testWidgets('the incoming episode\'s own intro auto-skips without a rebuild', (tester) async {
    await swapWhileHidden(tester);

    player.moveTo(const Duration(seconds: 65));
    await tester.pump(const Duration(seconds: 6));

    expect(seeks, [const Duration(milliseconds: incomingIntroEndMs)]);
    await finish(tester);
  });

  testWidgets('the rebuild that catches up after the swap keeps the incoming markers', (tester) async {
    await swapWhileHidden(tester);

    // The app is back: the screen's frame finally hands the controls the new item.
    await tester.pumpWidget(shell(controls(metadata: incoming)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));

    player.moveTo(const Duration(seconds: 65));
    await tester.pump(const Duration(seconds: 6));

    expect(seeks, [const Duration(milliseconds: incomingIntroEndMs)]);
    await finish(tester);
  });
}

const _windowChannel = MethodChannel('window_manager');

/// A [Player] whose position the test moves by hand.
class _PositionPlayer implements Player {
  final StreamController<bool> _playingController = StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  Duration _position = Duration.zero;

  void moveTo(Duration position) {
    _position = position;
    _positionController.add(position);
  }

  Future<void> close() async {
    await _playingController.close();
    await _positionController.close();
  }

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state =>
      PlayerState(playing: true, position: _position, duration: const Duration(minutes: 22), seekable: true);

  @override
  Future<void> seek(Duration position) async {}

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: _playingController.stream,
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: _positionController.stream,
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
