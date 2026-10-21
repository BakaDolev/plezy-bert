import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_role.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/actor_media_screen.dart';
import 'package:plezy/screens/episode_detail_screen.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/app_bar_back_button.dart';
import 'package:plezy/widgets/cast_member_strip.dart';
import 'package:plezy/widgets/cycling_media_backdrop.dart';
import 'package:plezy/widgets/media_progress_bar.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';
import 'episode_detail_test_support.dart'; // fake client + episode factory

/// Counts pushed routes so tests can assert navigation did (or did not)
/// happen without mounting/settling the pushed screen.
class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
  }
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  Future<void> pumpScreen(
    WidgetTester tester,
    MediaItem episode,
    FakeEpisodeClient client, {
    List<NavigatorObserver> observers = const [],
    bool isOffline = false,
  }) async {
    // CastMemberStrip reads SettingsService.instance synchronously for its
    // responsive card width, so it must be initialized before the pump.
    await SettingsService.getInstance();
    final provider = testMultiServer(clients: [client]).provider;
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MultiServerProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: monoTheme(dark: true),
            navigatorObservers: observers,
            home: withProfileNavigationScope(
              child: SizedBox(
                width: 1280,
                height: 720,
                // Keyed by episode id: without a key, two pumpScreen calls in one test
                // (e.g. "renders cast and hides the strip when empty") update the same
                // State in place rather than remounting it, so stale fetched data
                // (`_full`) from the first episode would leak into the second.
                child: EpisodeDetailScreen(key: ValueKey(episode.id), metadata: episode, isOffline: isOffline),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders episode title and a "Season N · Episode N" kicker from lean item', (tester) async {
    // Redesigned hero (Task A2) spells the kicker out in full — "Season 2 ·
    // Episode 5" — rather than the retired abbreviated "S2 · E5" meta line.
    final ep = fakeEpisode(title: 'The One With The Test', parentIndex: 2, index: 5);
    await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
    expect(find.text('The One With The Test'), findsOneWidget);
    expect(find.textContaining('Season 2'), findsOneWidget);
    expect(find.textContaining('Episode 5'), findsOneWidget);
  });

  testWidgets('specials (no season/episode number) do not render a "Season null" kicker', (tester) async {
    final ep = fakeEpisode(title: 'Special', parentIndex: null, index: null);
    await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
    expect(find.textContaining('Season'), findsNothing);
    expect(find.textContaining('Episode'), findsNothing);
  });

  testWidgets('fetches full metadata and shows summary once loaded', (tester) async {
    final lean = fakeEpisode(id: 'ep9', title: 'Loaded', summary: null);
    final full = fakeEpisode(id: 'ep9', title: 'Loaded', summary: 'The full plot summary.');
    final client = FakeEpisodeClient(item: full);
    await pumpScreen(tester, lean, client);
    await tester.pump(); // let the fetch future complete
    await tester.pump();
    expect(client.fetchItemCalls, 1);
    expect(find.text('The full plot summary.'), findsOneWidget);
  });

  testWidgets('keeps lean data when fetch returns null', (tester) async {
    final lean = fakeEpisode(id: 'epX', title: 'Still Here');
    final client = FakeEpisodeClient(item: null);
    await pumpScreen(tester, lean, client);
    await tester.pump();
    await tester.pump();
    expect(find.text('Still Here'), findsOneWidget); // no crash, lean title stays
  });

  testWidgets('renders cast and hides the strip when empty', (tester) async {
    final withCast = fakeEpisode(
      id: 'c1',
      roles: const [MediaRole(id: 'p1', tag: 'Actor One', role: 'Hero', thumbPath: null)],
    );
    await pumpScreen(tester, withCast, FakeEpisodeClient(item: withCast));
    await tester.pump();
    await tester.pump();
    expect(find.text('Actor One'), findsOneWidget);

    final noCast = fakeEpisode(id: 'c2', roles: const []);
    await pumpScreen(tester, noCast, FakeEpisodeClient(item: noCast));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CastMemberStrip), findsNothing);
  });

  testWidgets('renders writers and directors when present', (tester) async {
    final ep = fakeEpisode(id: 'w1', writers: const ['Ann Writer'], directors: const ['Dee Rector']);
    await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Ann Writer'), findsOneWidget);
    expect(find.textContaining('Dee Rector'), findsOneWidget);
  });

  testWidgets('cast member with no person id is non-tappable (no navigation)', (tester) async {
    final observer = _RecordingNavigatorObserver();
    final ep = fakeEpisode(
      id: 'noid1',
      roles: const [MediaRole(id: null, tag: 'No Id Actor', role: 'Cameo', thumbPath: null)],
    );
    await pumpScreen(tester, ep, FakeEpisodeClient(item: ep), observers: [observer]);
    await tester.pump();
    await tester.pump();

    // Non-vacuity: the member must actually render (and be tappable) before
    // we can claim the tap was a no-op rather than there being nothing to tap.
    expect(find.text('No Id Actor'), findsOneWidget);

    final pushesBeforeTap = observer.pushCount;
    // Single frame only — pumpAndSettle would trigger ActorMediaScreen's
    // async fetchPersonMediaPage load if navigation ever did occur, and
    // FakeEpisodeClient doesn't stub that method.
    await tester.tap(find.text('No Id Actor'));
    await tester.pump();

    expect(observer.pushCount, pushesBeforeTap, reason: 'tapping a cast member with no person id must not navigate');
    expect(find.byType(ActorMediaScreen), findsNothing);
  });

  testWidgets('Play button launches the video player with this episode', (tester) async {
    // navigateToVideoPlayer (video_player_navigation.dart) unconditionally
    // reads DownloadProvider/OfflineWatchSyncService before it ever reaches
    // Navigator.push, even for this online play — so this needs the same
    // provider stack MediaDetailScreen's own play-button push test builds
    // (media_detail_screen_test.dart), not just MultiServerProvider.
    final ep = fakeEpisode(id: 'p1', title: 'Playable');
    final client = FakeEpisodeClient(item: ep);
    await SettingsService.getInstance();

    final database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    JellyfinApiCache.initialize(database);
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final multiServerProvider = testMultiServerProvider(manager);
    final offlineWatch = OfflineWatchSyncService(database: database, serverManager: manager);
    final downloadManager = DownloadManagerService(
      database: database,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => null,
    )..recoveryFuture = Future<void>.value();
    final downloadProvider = DownloadProvider.forTesting(downloadManager: downloadManager, database: database);
    await downloadProvider.ensureInitialized();
    addTearDown(() async {
      downloadProvider.dispose();
      downloadManager.dispose();
      offlineWatch.dispose();
      multiServerProvider.dispose();
      manager.dispose();
      await database.close();
    });

    final observer = _RecordingNavigatorObserver();
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
            ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          ],
          child: MaterialApp(
            theme: monoTheme(dark: true),
            navigatorObservers: [observer],
            home: withProfileNavigationScope(
              child: SizedBox(width: 1280, height: 720, child: EpisodeDetailScreen(metadata: ep)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final pushesBeforeTap = observer.pushCount;
    // The hero still now pushes the action row below the fold on this wide
    // (1280x720) test viewport, so it must be scrolled into view first.
    await tester.ensureVisible(find.byIcon(Symbols.play_arrow_rounded));
    await tester.tap(find.byIcon(Symbols.play_arrow_rounded));
    await tester.pump(); // navigation attempted; do not settle into the video player route

    expect(observer.pushCount, greaterThan(pushesBeforeTap));
  });

  testWidgets('Play button shows the Resume icon and tooltip when the episode has progress', (tester) async {
    // Icon-only (no visible "Resume" text label, matching the show/movie
    // screen's convention for a non-show item — see the fix in
    // episode_detail_screen.dart) — the resume-vs-play state is asserted via
    // icon + tooltip/semantics label instead.
    final resumable = fakeEpisode(id: 'p2', title: 'Resumable', viewOffsetMs: 30000);
    await pumpScreen(tester, resumable, FakeEpisodeClient(item: resumable));

    expect(find.byIcon(Symbols.resume_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.play_arrow_rounded), findsNothing);
    expect(find.byTooltip(t.common.resume), findsOneWidget);
  });

  testWidgets('Play button shows the Play icon and tooltip when the episode has no progress', (tester) async {
    final fresh = fakeEpisode(id: 'p3', title: 'Fresh');
    await pumpScreen(tester, fresh, FakeEpisodeClient(item: fresh));

    expect(find.byIcon(Symbols.play_arrow_rounded), findsOneWidget);
    expect(find.byTooltip(t.common.play), findsOneWidget);
  });

  testWidgets('Go to show button navigates to the parent show', (tester) async {
    // The pushed target is MediaDetailScreen, which reads ProfileNavigationScope
    // in didChangeDependencies — pumpScreen()'s placement (scope inside `home:`,
    // matching MediaDetailScreen's own tests) only covers the FIRST route on
    // the Navigator, so this test wraps MaterialApp itself instead, making the
    // scope available to every route pushed on it, including this one.
    await SettingsService.getInstance();
    final observer = _RecordingNavigatorObserver();
    final ep = fakeEpisode(id: 'g1', title: 'Go To Show Me', grandparentId: 'show1', grandparentTitle: 'The Show');
    final provider = testMultiServer(clients: [FakeEpisodeClient(item: ep)]).provider;
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MultiServerProvider>.value(
          value: provider,
          child: withProfileNavigationScope(
            child: MaterialApp(
              theme: monoTheme(dark: true),
              navigatorObservers: [observer],
              home: SizedBox(width: 1280, height: 720, child: EpisodeDetailScreen(metadata: ep)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Deliberately no tester.pump() after the tap: Navigator.push notifies
    // observers synchronously as part of the push call, before the pushed
    // MediaDetailScreen's element tree is ever mounted/built — pumping here
    // would build its real hero header, which (unrelated to this task) reads
    // several more MediaServerClient members FakeEpisodeClient doesn't stub.
    final pushesBeforeTap = observer.pushCount;
    // Scrolling the still-showing EpisodeDetailScreen into position is safe
    // here — it happens before Navigator.push, so it never touches the
    // not-yet-mounted MediaDetailScreen the comment above guards against.
    await tester.ensureVisible(find.byIcon(Symbols.tv_rounded));
    await tester.tap(find.byIcon(Symbols.tv_rounded));

    expect(observer.pushCount, greaterThan(pushesBeforeTap));
  });

  testWidgets('watched-toggle icon and tooltip reflect unwatched vs watched state', (tester) async {
    final unwatched = fakeEpisode(id: 'w1', title: 'Unwatched');
    await pumpScreen(tester, unwatched, FakeEpisodeClient(item: unwatched));
    expect(find.byIcon(Symbols.check_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.remove_done_rounded), findsNothing);
    expect(
      find.byTooltip(t.tooltips.markAsWatched),
      findsOneWidget,
      reason: 'unwatched episode offers "mark as watched"',
    );

    final watched = fakeEpisode(id: 'w2', title: 'Watched', viewCount: 1);
    await pumpScreen(tester, watched, FakeEpisodeClient(item: watched));
    expect(find.byIcon(Symbols.remove_done_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.check_rounded), findsNothing);
    expect(
      find.byTooltip(t.tooltips.markAsUnwatched),
      findsOneWidget,
      reason: 'watched episode offers "mark as unwatched"',
    );
  });

  testWidgets('tapping the watched toggle marks an unwatched episode watched via WatchActions', (tester) async {
    final ep = fakeEpisode(id: 'wt1', title: 'Toggle Me');
    final client = FakeEpisodeClient(item: ep);
    await pumpScreen(tester, ep, client);

    await tester.ensureVisible(find.byIcon(Symbols.check_rounded));
    await tester.tap(find.byIcon(Symbols.check_rounded));
    // Multiple single frames (not pumpAndSettle) to let WatchActions.setWatched's
    // await chain (client.markWatched, then this screen's own _loadFull refetch)
    // settle without falling into any un-stubbed FakeEpisodeClient method.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(client.markWatchedCalls, 1);
    expect(client.markUnwatchedCalls, 0);
  });

  testWidgets('tapping the watched toggle marks a watched episode unwatched via WatchActions', (tester) async {
    final ep = fakeEpisode(id: 'wt2', title: 'Toggle Me Back', viewCount: 1);
    final client = FakeEpisodeClient(item: ep);
    await pumpScreen(tester, ep, client);

    await tester.ensureVisible(find.byIcon(Symbols.remove_done_rounded));
    await tester.tap(find.byIcon(Symbols.remove_done_rounded));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(client.markUnwatchedCalls, 1);
    expect(client.markWatchedCalls, 0);
  });

  testWidgets('returns true from its route after a watched-state change (route-result plumbing)', (tester) async {
    final ep = fakeEpisode(id: 'route1', title: 'Route Result');
    final client = FakeEpisodeClient(item: ep);
    await SettingsService.getInstance();
    final provider = testMultiServer(clients: [client]).provider;
    bool? poppedResult;

    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<MultiServerProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: monoTheme(dark: true),
            home: withProfileNavigationScope(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    poppedResult = await Navigator.push<bool>(context, episodeDetailRoute(metadata: ep));
                  },
                  child: const Text('open episode'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open episode'));
    await tester.pump(); // push the route
    await tester.pump(); // let initState's _loadFull settle
    await tester.pump();

    await tester.ensureVisible(find.byIcon(Symbols.check_rounded));
    await tester.tap(find.byIcon(Symbols.check_rounded)); // unwatched -> tap marks watched
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Explicit AppBarBackButton pop (see EpisodeDetailScreen._buildNonTvScaffold)
    // — this is the non-TV/keyboard path exercised here
    // (InputModeTracker.shouldBlockSystemBack is false on the test host
    // platform, so no PopScope is in play). The back button is overlaid on
    // the backdrop as a Stack sibling of the scroll view (not inside the
    // scrolled content), so it's always hittable regardless of scroll offset.
    await tester.tap(find.byType(AppBarBackButton).hitTestable());
    await tester.pump();
    await tester.pump();

    expect(poppedResult, isTrue, reason: 'watch state changed under the screen, so it must pop true');
  });

  testWidgets('renders the hero still image when the episode has a thumb path', (tester) async {
    final ep = fakeEpisode(id: 'hero1', title: 'Has A Still', thumbPath: '/library/metadata/hero1/thumb');
    await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));

    expect(find.byType(OptimizedMediaImage), findsWidgets);
  });

  testWidgets('shows a resume progress bar with the correct fraction when partially watched', (tester) async {
    final ep = fakeEpisode(id: 'hero2', title: 'Partway Through', viewOffsetMs: 30000, durationMs: 120000);
    await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));

    final bar = tester.widget<MediaProgressBar>(find.byType(MediaProgressBar));
    expect(bar.viewOffset, 30000);
    expect(bar.duration, 120000);
  });

  testWidgets('does not show a resume progress bar when there is no progress', (tester) async {
    final ep = fakeEpisode(id: 'hero3', title: 'Fresh Episode', durationMs: 120000);
    await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));

    expect(find.byType(MediaProgressBar), findsNothing);
  });

  testWidgets('offline episode with a hero still does not crash', (tester) async {
    final ep = fakeEpisode(id: 'hero4', title: 'Offline Episode', thumbPath: '/library/metadata/hero4/thumb');
    await pumpScreen(tester, ep, FakeEpisodeClient(item: ep), isOffline: true);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Offline Episode'), findsOneWidget);
  });

  group('action row fits at real phone widths', () {
    // Regression test for the FocusableActionBar action row overflowing
    // RenderFlex on real phone widths once the Play button carried a text
    // label ("Play"/"Resume") — resizes the ACTUAL test viewport (not just
    // pumpScreen's SizedBox, which only clamps the upper bound) to a phone
    // width, mirroring how media_detail_screen_test.dart sets
    // tester.view.physicalSize/devicePixelRatio for its own narrow-viewport
    // cases.
    Future<void> pumpAtWidth(WidgetTester tester, double width, MediaItem ep, FakeEpisodeClient client) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpScreen(tester, ep, client);
    }

    testWidgets('does not overflow at 360dp for a fresh (Play-label) episode', (tester) async {
      final ep = fakeEpisode(id: 'w360-fresh', title: 'Fresh At 360dp');
      await pumpAtWidth(tester, 360, ep, FakeEpisodeClient(item: ep));

      expect(tester.takeException(), isNull);
    });

    testWidgets('does not overflow at 360dp for a resumable (Resume-label) episode', (tester) async {
      final ep = fakeEpisode(id: 'w360-resume', title: 'Resume At 360dp', viewOffsetMs: 30000);
      await pumpAtWidth(tester, 360, ep, FakeEpisodeClient(item: ep));

      expect(tester.takeException(), isNull);
    });

    testWidgets('does not overflow at 320dp for a fresh (Play-label) episode', (tester) async {
      final ep = fakeEpisode(id: 'w320-fresh', title: 'Fresh At 320dp');
      await pumpAtWidth(tester, 320, ep, FakeEpisodeClient(item: ep));

      expect(tester.takeException(), isNull);
    });

    testWidgets('does not overflow at 320dp for a resumable (Resume-label) episode', (tester) async {
      final ep = fakeEpisode(id: 'w320-resume', title: 'Resume At 320dp', viewOffsetMs: 30000);
      await pumpAtWidth(tester, 320, ep, FakeEpisodeClient(item: ep));

      expect(tester.takeException(), isNull);
    });
  });

  group('hero sizing (Task A2 backdrop hero)', () {
    // Regression coverage for what the Task-10a "hero sizing at wide
    // viewport" test protected (the hero must not push the title/action-row/
    // cast section below the fold), re-expressed for the redesigned
    // show-style backdrop hero: the hero's *height* — not a still-only
    // width cap — is now what's bounded (see `_heroHeight` in
    // episode_detail_screen.dart), and the hero composes a backdrop, a
    // kicker/title/chip stack, and the still inset all at once, any of which
    // could in principle overflow a short hero if not guarded.
    testWidgets('hero height is bounded to 60% of the screen height at a wide desktop viewport', (tester) async {
      // Resizes the ACTUAL test viewport (not just pumpScreen's SizedBox,
      // which only clamps the upper bound — see the phone-width group above)
      // to a desktop width, so the hero's rendered size reflects real
      // available width rather than being clamped by that SizedBox.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ep = fakeEpisode(
        id: 'heroCap1',
        title: 'Wide Hero',
        thumbPath: '/library/metadata/heroCap1/thumb',
        viewOffsetMs: 30000,
        durationMs: 120000,
      );
      await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
      await tester.pump();

      expect(tester.takeException(), isNull, reason: 'the hero must not overflow at a wide desktop viewport');

      final heroSize = tester.getSize(find.byKey(const Key('episodeHeroSection')));
      expect(
        heroSize.height,
        lessThanOrEqualTo(800 * 0.6 + 0.5), // +0.5: float rounding slack
        reason: 'hero height must be capped at 60% of the screen height, or it pushes action-row/cast below the fold',
      );

      // The still inset (this screen's only AspectRatio) and its resume bar
      // still render inside the redesigned hero.
      expect(find.byType(AspectRatio), findsOneWidget);
      expect(find.byType(MediaProgressBar), findsOneWidget);

      // Non-vacuity / belt-and-suspenders: with the hero capped, the action
      // row (which sits below it, above cast) is also within the viewport's
      // vertical bounds without scrolling. `ep` has progress (viewOffsetMs
      // set above), so the Play button renders as Resume.
      final actionRowBottom = tester.getBottomLeft(find.byIcon(Symbols.resume_rounded)).dy;
      expect(
        actionRowBottom,
        lessThanOrEqualTo(800),
        reason: 'action row must be above the fold at this viewport height once the hero is capped',
      );
    });

    testWidgets('hero content does not overflow at a narrow phone viewport', (tester) async {
      // The phone layout stacks the still inset above a kicker + a
      // (potentially 2-line) title + a (potentially 2-row) chip wrap inside
      // the hero's bounded height (`_heroHeight`, floored at 220 — see
      // episode_detail_screen.dart) — the exact shape that could overflow a
      // short/narrow hero if that floor weren't generous enough.
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ep = fakeEpisode(
        id: 'heroCap2',
        title: 'A Narrow-Viewport Title Long Enough To Wrap Across Two Lines',
        thumbPath: '/library/metadata/heroCap2/thumb',
        durationMs: 120000,
        contentRating: 'TV-14',
        originallyAvailableAt: '2020-01-01',
      );
      await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'hero content (kicker/title/chips/still) must not overflow at a narrow phone viewport',
      );
      expect(find.byType(AspectRatio), findsOneWidget);

      // Regression for S16-episode-phone-layout: the phone stacks the still
      // ABOVE the title, taller than the wide-tuned fixed hero box, so the
      // block used to overflow UPWARD to the very top of the window — the
      // still riding under the status bar and the overlaid back button. The
      // fix lays the phone stack out in natural flow beneath a top clear zone
      // (status bar + [kToolbarHeight]); with zero simulated status-bar
      // padding here that clear zone is kToolbarHeight, so the still's top
      // must sit at least that far down — never up at y≈0.
      final stillTop = tester.getTopLeft(find.byType(AspectRatio)).dy;
      expect(
        stillTop,
        greaterThanOrEqualTo(kToolbarHeight - 0.5),
        reason: 'the phone still must clear the top back-button/status-bar zone, not ride up under it',
      );
    });
  });

  group('hero backdrop + metadata chips (Task A2)', () {
    testWidgets('hero renders a CyclingMediaBackdrop, the title, a metadata chip, and the still inset', (tester) async {
      final ep = fakeEpisode(
        id: 'heroBackdrop1',
        title: 'Backdrop Episode',
        thumbPath: '/library/metadata/heroBackdrop1/thumb',
        grandparentArtPath: '/library/metadata/show1/art',
        durationMs: 1320000, // 22m — renders as a runtime chip
      );
      await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
      await tester.pump();

      expect(find.byType(CyclingMediaBackdrop), findsOneWidget);
      expect(find.text('Backdrop Episode'), findsOneWidget);
      // The runtime chip is the metadata chip guaranteed to render from just
      // `durationMs` — the fake client stubs no ratings/quality data.
      expect(find.textContaining('22'), findsWidgets);
      expect(find.byType(AspectRatio), findsOneWidget, reason: 'the episode-still inset must still render');
    });
  });

  group('hero bleeds to the top of the window, no AppBar seam (Task P1)', () {
    testWidgets('non-TV scaffold has no AppBar and the backdrop reaches the very top of the window', (tester) async {
      // Regression coverage for the reported "black bar above the backdrop"
      // bug: the old bounded-box hero sat below a real AppBar/back-button
      // strip. The restructured hero has no AppBar on non-TV at all — the
      // backdrop is a Positioned background layer pinned to y=0 (see
      // EpisodeDetailScreen._buildHeroBackdropLayer), matching the show
      // detail screen's own bleed-to-top treatment.
      // grandparentArtPath (not thumbPath) is what an episode's
      // heroArtCandidates resolves to (media_item.dart) — thumbPath alone
      // renders only the still inset, not the backdrop this test checks.
      final ep = fakeEpisode(
        id: 'bleed1',
        title: 'Bleeds To Top',
        thumbPath: '/library/metadata/bleed1/thumb',
        grandparentArtPath: '/library/metadata/show1/art',
      );
      await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
      await tester.pump();

      expect(find.byType(AppBar), findsNothing, reason: 'non-TV no longer renders an AppBar strip above the hero');

      final backdropTop = tester.getTopLeft(find.byType(CyclingMediaBackdrop)).dy;
      expect(backdropTop, 0, reason: 'the backdrop must bleed to the very top of the window, matching the show hero');

      // The back button now overlays the backdrop directly instead of living
      // in an AppBar.
      expect(find.byType(AppBarBackButton), findsOneWidget);
    });

    testWidgets('back button stays hittable after scrolling and pops with the current _changed flag', (tester) async {
      // The back button is a Stack sibling of the SingleChildScrollView (see
      // EpisodeDetailScreen._buildNonTvScaffold), not a child of the scrolled
      // Column — this asserts that structural placement holds by scrolling
      // first, then confirming the button still pops the route.
      final ep = fakeEpisode(id: 'bleed2', title: 'Scroll Then Back');
      final client = FakeEpisodeClient(item: ep);
      await SettingsService.getInstance();
      final provider = testMultiServer(clients: [client]).provider;
      bool? poppedResult;

      await tester.pumpWidget(
        TranslationProvider(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(
              theme: monoTheme(dark: true),
              home: withProfileNavigationScope(
                child: Builder(
                  builder: (context) => ElevatedButton(
                    onPressed: () async {
                      poppedResult = await Navigator.push<bool>(context, episodeDetailRoute(metadata: ep));
                    },
                    child: const Text('open episode'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open episode'));
      await tester.pump(); // push the route
      await tester.pump(); // let initState's _loadFull settle
      await tester.pump();

      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -200));
      await tester.pump();

      await tester.tap(find.byType(AppBarBackButton).hitTestable());
      await tester.pump();
      await tester.pump();

      expect(poppedResult, isFalse, reason: 'no watch-state change occurred, so it pops with _changed == false');
    });
  });

  group('TV D-pad focus', () {
    setUp(() {
      TvDetectionService.debugSetAppleTVOverride(true);
    });

    tearDown(() {
      TvDetectionService.debugSetAppleTVOverride(null);
    });

    testWidgets('TV mode autofocuses the Play button, and only the Play button', (tester) async {
      final ep = fakeEpisode(
        id: 'tv1',
        title: 'TV Focus',
        roles: const [MediaRole(id: 'p1', tag: 'Actor One', role: 'Hero', thumbPath: null)],
      );
      await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
      await tester.pump();
      await tester.pump();

      // primaryFocus is singular — this being 'episode_play' is proof no
      // other focusable widget (the cast strip included) also won autofocus.
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode_play');
    });

    testWidgets('D-pad DOWN moves focus from the action row to the cast strip, and UP returns', (tester) async {
      final ep = fakeEpisode(
        id: 'tv2',
        title: 'TV Traverse',
        roles: const [MediaRole(id: 'p1', tag: 'Actor One', role: 'Hero', thumbPath: null)],
      );
      await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode_play');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      // 'cast_row' is CastMemberStrip's default debugLabel (cast_member_strip.dart).
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'cast_row');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode_play');
    });

    testWidgets('D-pad DOWN from the action row is a no-op when there is no cast to reach', (tester) async {
      final ep = fakeEpisode(id: 'tv3', title: 'No Cast', roles: const []);
      await pumpScreen(tester, ep, FakeEpisodeClient(item: ep));
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode_play');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode_play');
    });
  });
}
