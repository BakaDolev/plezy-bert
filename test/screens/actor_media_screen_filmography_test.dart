import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;
import 'package:plezy/widgets/focusable_media_card.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

/// The actor screen's "In your library" section: a single grid of the titles
/// the person appears in on the local server, each captioned with the year and
/// the character they play (once resolved). Role tabs now belong to the online
/// filmography (from Plex Discover), not this local grid.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('one library title: grid shows the character caption, no tab bar', (tester) async {
    final titles = [
      testMediaItem(
        id: 'acted_1',
        kind: MediaKind.movie,
        title: 'The Big Case',
        year: 2010,
        serverId: 'server_1',
        serverName: 'Server',
        roles: [MediaRole(id: 'credit-1', tag: 'Jane Doe', role: 'Detective Ruiz')],
      ),
    ];
    final harness = await _createHarness(titles);

    await tester.pumpWidget(harness.wrap(const _Host()));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // No online filmography here (enrichment off), so no tab bar at all.
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(FocusableMediaCard), findsOneWidget);
    // Caption is "{year} · {character}", stamped onto the tile subtitle.
    expect(find.textContaining('Detective Ruiz'), findsOneWidget);
    expect(find.textContaining('2010'), findsOneWidget);
  });

  testWidgets('every library title shows in one grid (no role tabs); acted titles keep their character', (tester) async {
    final titles = [
      testMediaItem(
        id: 'acted_1',
        kind: MediaKind.movie,
        title: 'ActedFilm',
        year: 2010,
        serverId: 'server_1',
        serverName: 'Server',
        roles: [MediaRole(id: 'credit-1', tag: 'Jane Doe', role: 'Detective Ruiz')],
      ),
      testMediaItem(
        id: 'directed_1',
        kind: MediaKind.movie,
        title: 'DirectedFilm',
        year: 2018,
        serverId: 'server_1',
        serverName: 'Server',
        directors: const ['Jane Doe'],
      ),
    ];
    final harness = await _createHarness(titles);

    await tester.pumpWidget(harness.wrap(const _Host()));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The library section is a single grid — both titles show, no role tab bar.
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(FocusableMediaCard), findsNWidgets(2));
    expect(find.text('ActedFilm'), findsOneWidget);
    expect(find.text('DirectedFilm'), findsOneWidget);
    expect(find.textContaining('Detective Ruiz'), findsOneWidget);
  });
}

class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
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

Future<_Harness> _createHarness(List<MediaItem> titles) async {
  await SettingsService.getInstance();
  // Enrichment off keeps the hero library-only (no network) — this suite
  // exercises the filmography body, not enrichment.
  await SettingsService.instance.write(SettingsService.actorEnrichmentEnabled, false);

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

  final client = _FilmographyClient(titles);
  final manager = MultiServerManager()..debugRegisterClientForTesting(client);
  final multiServerProvider = testMultiServerProvider(manager);

  addTearDown(() async {
    downloadProvider.dispose();
    downloadManager.dispose();
    multiServerProvider.dispose();
    await database.close();
  });

  return _Harness(multiServerProvider: multiServerProvider, downloadProvider: downloadProvider);
}

class _Harness {
  final MultiServerProvider multiServerProvider;
  final DownloadProvider downloadProvider;

  const _Harness({required this.multiServerProvider, required this.downloadProvider});

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

class _FilmographyClient implements MediaServerClient {
  final List<MediaItem> titles;

  const _FilmographyClient(this.titles);

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Future<MediaItem?> fetchItem(String id) async => null;

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    return LibraryPage<MediaItem>(items: titles, totalCount: titles.length, offset: 0);
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
