import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_role.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/actor_media_screen.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/enrichment/actor_info.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/grid_size_calculator.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/actor_hero_header.dart';
import 'package:plezy/widgets/focusable_media_card.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/paged_fakes.dart';
import '../test_helpers/prefs.dart';

/// Actor screen TV focus behaviour. Originally the whole hero was decorative
/// (wrapped in [ExcludeFocus]) so only the grid took D-pad focus. As of
/// S16-actor-bio-toggle the collapsible bio is a deliberate D-pad target so the
/// remote can expand/collapse it, while everything else in the header stays a
/// non-target. Covers:
///  1. On TV the header is NOT under [ExcludeFocus] (the bio is reachable), yet
///     initial focus still lands on the grid, not the bio.
///  2. On non-TV the header is likewise not wrapped in [ExcludeFocus] — a
///     regression guard against re-introducing the old exclusion.
///  3. Given a bio focus node (the TV wiring), the bio is a focusable D-pad
///     target that expands on Select and routes DOWN to the grid.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  testWidgets('TV: the actor header is not focus-excluded so its sections are D-pad reachable', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    final harness = await _createHarness([_movie('movie_1'), _movie('movie_2')]);

    await tester.pumpWidget(harness.wrap(const _ActorScreenHost()));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The header is no longer wrapped in ExcludeFocus on TV — the bio and the
    // sections below are deliberate D-pad targets now, and the page opens at
    // the top rather than auto-jumping focus to the grid (S16-actor-dpad).
    expect(
      find.ancestor(of: find.byType(ActorHeroHeader), matching: find.byType(ExcludeFocus)),
      findsNothing,
      reason: 'header must not be focus-excluded on TV once its sections are D-pad targets',
    );
    expect(find.byType(FocusableMediaCard), findsWidgets);
  });

  testWidgets('TV: the library grid uses the compact card size so a full row fits under the pinned hero', (
    tester,
  ) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    final harness = await _createHarness([_movie('movie_1'), _movie('movie_2')]);

    await tester.pumpWidget(harness.wrap(const _ActorScreenHost()));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final compactExtent = GridSizeCalculator.getMaxCrossAxisExtent(
      tester.element(find.byType(ActorMediaScreen)),
      LibraryDensity.min,
    );
    expect(
      tester.getSize(find.byType(FocusableMediaCard).first).width,
      lessThanOrEqualTo(compactExtent),
      reason: 'the default library density sizes cards for a full-screen grid, too tall under the hero',
    );
  });

  testWidgets('non-TV: header is NOT wrapped in ExcludeFocus (regression guard)', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(false);
    final harness = await _createHarness([_movie('movie_1')]);

    await tester.pumpWidget(harness.wrap(const _ActorScreenHost()));
    await tester.pump();
    await tester.pump();

    expect(find.ancestor(of: find.byType(ActorHeroHeader), matching: find.byType(ExcludeFocus)), findsNothing);
  });

  testWidgets('TV: the bio is a "Read more" D-pad target that opens the popup and routes DOWN', (tester) async {
    const longBio =
        'A celebrated performer known for many memorable roles across film and '
        'television, with a career spanning several decades and numerous awards.';
    const info = ActorInfo(bio: longBio);
    final bioNode = FocusNode(debugLabel: 'test_actor_bio');
    addTearDown(bioNode.dispose);
    var readMoreCount = 0;
    var downCount = 0;

    await tester.pumpWidget(
      // Real app hosts the hero inside a CustomScrollView's SliverToBoxAdapter
      // (see ActorMediaScreen._buildActorHeader), so mirror that scrollable
      // shape here rather than a fixed-height body. monoTheme(dark: true) puts
      // MonoTokens on the tree (used by the portrait card corner radius).
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: SingleChildScrollView(
            // TV-realistic width — the compact TV hero is a portrait + facts
            // Row, laid out for a 10-foot screen, not a 320px phone.
            child: SizedBox(
              width: 960,
              child: ActorHeroHeader(
                actorName: 'Jane Doe',
                titleCount: 1,
                enrichment: info,
                isTv: true,
                bioFocusNode: bioNode,
                onBioReadMore: () => readMoreCount++,
                onBioNavigateDown: () => downCount++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // TV shows a focusable "Read more" control (the full bio opens in a popup,
    // not inline), rather than the inline show-more/less used on the phone.
    expect(find.text('Read more'), findsOneWidget);

    expect(bioNode.canRequestFocus, isTrue);
    bioNode.requestFocus();
    await tester.pump();
    expect(bioNode.hasFocus, isTrue);

    // Select opens the full-bio popup (via the callback), not an inline expand.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(readMoreCount, 1);

    // DOWN routes to the next section down the chain.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(downCount, 1);
  });
}

MediaItem _movie(String id) => testMediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: id,
  serverId: 'server_1',
  serverName: 'Server',
  // A cast credit tagged with the screen's actor so the title buckets into
  // the Acting filmography tab and the grid renders.
  roles: [MediaRole(id: 'credit-$id', tag: 'Jane Doe', role: 'Herself')],
);

/// Fixed-size host so [MediaCardSliverLayout] lays out a real grid.
class _ActorScreenHost extends StatelessWidget {
  const _ActorScreenHost();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1280,
      height: 720,
      child: ActorMediaScreen(
        actorName: 'Jane Doe',
        personId: 'person_1',
        serverId: 'server_1',
        serverName: 'Server',
        backend: MediaBackend.plex,
      ),
    );
  }
}

Future<_ActorHarness> _createHarness(List<MediaItem> items) async {
  await SettingsService.getInstance();

  final database = AppDatabase.forTesting(NativeDatabase.memory());
  PlexApiCache.initialize(database);
  JellyfinApiCache.initialize(database);

  final downloadManager = DownloadManagerService(
    database: database,
    storageService: DownloadStorageService.instance,
    clientResolver: (serverId, {clientScopeId}) => null,
  );
  downloadManager.recoveryFuture = Future<void>.value();
  final downloadProvider = DownloadProvider.forTesting(downloadManager: downloadManager, database: database);
  await downloadProvider.ensureInitialized();

  final client = _ActorClient(items);
  final manager = MultiServerManager()..debugRegisterClientForTesting(client);
  final multiServerProvider = testMultiServerProvider(manager);

  addTearDown(() async {
    downloadProvider.dispose();
    downloadManager.dispose();
    multiServerProvider.dispose();
    await database.close();
  });

  return _ActorHarness(multiServerProvider: multiServerProvider, downloadProvider: downloadProvider);
}

class _ActorHarness {
  final MultiServerProvider multiServerProvider;
  final DownloadProvider downloadProvider;

  const _ActorHarness({required this.multiServerProvider, required this.downloadProvider});

  Widget wrap(Widget child) {
    return InputModeTracker(
      child: TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
          ],
          child: MaterialApp(theme: monoTheme(dark: true), home: child),
        ),
      ),
    );
  }
}

class _ActorClient implements MediaServerClient {
  final List<MediaItem> items;

  const _ActorClient(this.items);

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    return fakeLibraryPage(items, start: start, size: size);
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
