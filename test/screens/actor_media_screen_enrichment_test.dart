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
import 'package:plezy/services/api_cache.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/enrichment/actor_enrichment_client.dart';
import 'package:plezy/services/enrichment/actor_enrichment_service.dart';
import 'package:plezy/services/enrichment/actor_info.dart';
import 'package:plezy/services/enrichment/person_online_page.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/active_client_scope.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/focusable_media_card.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/paged_fakes.dart';
import '../test_helpers/prefs.dart';

/// Task 10 (feat/actor-enrichment): wires the real enrichment service into
/// [ActorMediaScreen] via `_startEnrichment` — Plex routes through
/// [ActorEnrichmentService.enrichPlex] (Wikidata), Jellyfin/Emby through
/// [ActorEnrichmentService.enrichJellyfin] (server Person metadata), gated on
/// the `actorEnrichmentEnabled` setting, and always degrades to
/// library-only on error/null without crashing or stealing D-pad focus from
/// the grid.
///
/// Exercised through [ActorMediaScreen.debugEnrichmentServiceFactory], the
/// test seam that swaps in a canned [_FakeEnrichmentService] instead of the
/// real network client — no HTTP traffic in these tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  tearDown(() {
    ActorMediaScreen.debugEnrichmentServiceFactory = null;
    ActorMediaScreen.debugOnlinePersonPageFetcher = null;
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  // #68: an actor opened from Search has no plex.tv person key. The page asks
  // the server for it, then loads the online page (bio, Known For, the full
  // filmography) as it does for an actor opened from a Cast row.
  testWidgets('opened without a person key: looks the key up on the server and loads the online page', (tester) async {
    final harness = await _createHarness([_movie('movie_1')], backend: MediaBackend.plex, plexPersonTagKey: 'tag-123');
    final client = ActorEnrichmentClient();
    addTearDown(client.dispose);
    final fake = _FakeEnrichmentService(
      PlexApiCache.instance,
      client,
      plexResult: const ActorInfo(bio: 'From Wikidata.'),
    );
    ActorMediaScreen.debugEnrichmentServiceFactory = (cache) => fake;
    final asked = <String>[];
    ActorMediaScreen.debugOnlinePersonPageFetcher = (tagKey) async {
      asked.add(tagKey);
      return const PersonOnlinePage(bio: 'From the online page.');
    };

    await tester.pumpWidget(harness.wrap(_host(backend: MediaBackend.plex)));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(asked, ['tag-123']);
    expect(fake.enrichPlexCalled, isFalse);
    expect(find.text('From the online page.'), findsOneWidget);
  });

  testWidgets('a server with no key for the person keeps the Wikidata fallback', (tester) async {
    final harness = await _createHarness([_movie('movie_1')], backend: MediaBackend.plex, plexPersonTagKey: null);
    final client = ActorEnrichmentClient();
    addTearDown(client.dispose);
    final fake = _FakeEnrichmentService(
      PlexApiCache.instance,
      client,
      plexResult: const ActorInfo(bio: 'From Wikidata.'),
    );
    ActorMediaScreen.debugEnrichmentServiceFactory = (cache) => fake;
    final asked = <String>[];
    ActorMediaScreen.debugOnlinePersonPageFetcher = (tagKey) async {
      asked.add(tagKey);
      return const PersonOnlinePage(bio: 'From the online page.');
    };

    await tester.pumpWidget(harness.wrap(_host(backend: MediaBackend.plex)));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(asked, isEmpty);
    expect(fake.enrichPlexCalled, isTrue);
    expect(find.text('From Wikidata.'), findsOneWidget);
  });

  testWidgets('Plex backend + setting on: calls enrichPlex (not enrichJellyfin), hero fills in', (tester) async {
    final harness = await _createHarness([_movie('movie_1')], backend: MediaBackend.plex);
    final client = ActorEnrichmentClient();
    addTearDown(client.dispose);
    const info = ActorInfo(bio: 'A celebrated performer.', occupations: ['Actor']);
    final fake = _FakeEnrichmentService(PlexApiCache.instance, client, plexResult: info);
    ActorMediaScreen.debugEnrichmentServiceFactory = (cache) => fake;

    await tester.pumpWidget(harness.wrap(_host(backend: MediaBackend.plex)));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(fake.enrichPlexCalled, isTrue);
    expect(fake.enrichJellyfinCalled, isFalse);
    expect(fake.lastServerId, 'server_1');
    expect(fake.lastPersonId, 'person_1');
    expect(fake.lastName, 'Jane Doe');
    expect(find.text('A celebrated performer.'), findsOneWidget);
    expect(find.textContaining('Actor'), findsOneWidget);
  });

  testWidgets('Jellyfin backend: calls enrichJellyfin (not enrichPlex), never touches the Wikidata client', (
    tester,
  ) async {
    final harness = await _createHarness([_movie('movie_1')], backend: MediaBackend.jellyfin);
    final client = ActorEnrichmentClient();
    addTearDown(client.dispose);
    const info = ActorInfo(bio: 'Jellyfin bio.');
    final fake = _FakeEnrichmentService(JellyfinApiCache.instance, client, jellyfinResult: info);
    ActorMediaScreen.debugEnrichmentServiceFactory = (cache) => fake;

    await tester.pumpWidget(harness.wrap(_host(backend: MediaBackend.jellyfin)));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(fake.enrichJellyfinCalled, isTrue);
    expect(fake.enrichPlexCalled, isFalse);
    expect(find.text('Jellyfin bio.'), findsOneWidget);
  });

  testWidgets('setting off: neither enrichPlex nor enrichJellyfin is called, hero stays library-only', (tester) async {
    final harness = await _createHarness([_movie('movie_1')], backend: MediaBackend.plex);
    await SettingsService.instance.write(SettingsService.actorEnrichmentEnabled, false);
    final client = ActorEnrichmentClient();
    addTearDown(client.dispose);
    const info = ActorInfo(bio: 'Should never appear.');
    final fake = _FakeEnrichmentService(PlexApiCache.instance, client, plexResult: info, jellyfinResult: info);
    ActorMediaScreen.debugEnrichmentServiceFactory = (cache) => fake;

    await tester.pumpWidget(harness.wrap(_host(backend: MediaBackend.plex)));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(fake.enrichPlexCalled, isFalse);
    expect(fake.enrichJellyfinCalled, isFalse);
    expect(find.text('Should never appear.'), findsNothing);
  });

  testWidgets('enrichment returns null: hero stays library-only, no crash, grid keeps D-pad focus', (tester) async {
    // Auto-focusing the first grid tile only fires in keyboard/D-pad input
    // mode, whose default is TV-only (`InputModeTracker._defaultMode`) — TV
    // forced here, same as Task 9's focus-safety harness, purely so the
    // assertion below is meaningful.
    TvDetectionService.debugSetAppleTVOverride(true);
    final harness = await _createHarness([_movie('movie_1'), _movie('movie_2')], backend: MediaBackend.plex);
    final client = ActorEnrichmentClient();
    addTearDown(client.dispose);
    final fake = _FakeEnrichmentService(PlexApiCache.instance, client, plexResult: null);
    ActorMediaScreen.debugEnrichmentServiceFactory = (cache) => fake;

    await tester.pumpWidget(harness.wrap(_host(backend: MediaBackend.plex)));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(fake.enrichPlexCalled, isTrue);
    expect(tester.takeException(), isNull);
    // autoFocusFirstItemAfterLoad() claims `firstItemFocusNode`
    // (FocusableDetailScreenMixin), whose debugLabel is fixed at
    // 'detail_first_item' regardless of which grid tile borrows it.
    expect(tester.binding.focusManager.primaryFocus?.debugLabel, 'detail_first_item');
    expect(find.byType(FocusableMediaCard), findsWidgets);
  });

  testWidgets('enrichment throws: hero stays library-only, no crash, grid keeps D-pad focus', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    final harness = await _createHarness([_movie('movie_1')], backend: MediaBackend.plex);
    final client = ActorEnrichmentClient();
    addTearDown(client.dispose);
    final fake = _FakeEnrichmentService(PlexApiCache.instance, client, throwOnPlex: true);
    ActorMediaScreen.debugEnrichmentServiceFactory = (cache) => fake;

    await tester.pumpWidget(harness.wrap(_host(backend: MediaBackend.plex)));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(fake.enrichPlexCalled, isTrue);
    expect(tester.takeException(), isNull);
    expect(tester.binding.focusManager.primaryFocus?.debugLabel, 'detail_first_item');
  });
}

/// A canned [ActorEnrichmentService]: overrides both lookup methods so no
/// cache/network call is ever made, and records which one was invoked (and
/// with what arguments) for assertions. The `cache`/`client` passed to the
/// super constructor are never touched by the overrides — they only exist to
/// satisfy the real service's constructor.
class _FakeEnrichmentService extends ActorEnrichmentService {
  final ActorInfo? plexResult;
  final ActorInfo? jellyfinResult;
  final bool throwOnPlex;

  bool enrichPlexCalled = false;
  bool enrichJellyfinCalled = false;
  String? lastServerId;
  String? lastPersonId;
  String? lastName;

  _FakeEnrichmentService(super.cache, super.client, {this.plexResult, this.jellyfinResult, this.throwOnPlex = false});

  @override
  Future<ActorInfo?> enrichPlex({
    required String serverId,
    required String personId,
    required String name,
    String? localeCode,
    bool online = true,
  }) async {
    enrichPlexCalled = true;
    lastServerId = serverId;
    lastPersonId = personId;
    lastName = name;
    if (throwOnPlex) throw Exception('fake enrichPlex failure');
    return plexResult;
  }

  @override
  Future<ActorInfo?> enrichJellyfin({required MediaItem? person}) async {
    enrichJellyfinCalled = true;
    return jellyfinResult;
  }
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

/// Fixed-size host so `MediaCardSliverLayout` lays out a real grid, mirroring
/// `actor_media_screen_tv_test.dart`'s harness.
Widget _host({required MediaBackend backend}) {
  return SizedBox(
    width: 1280,
    height: 720,
    child: ActorMediaScreen(
      actorName: 'Jane Doe',
      personId: 'person_1',
      serverId: 'server_1',
      serverName: 'Server',
      backend: backend,
    ),
  );
}

/// [plexPersonTagKey]: when the parameter is passed at all, the client is a Plex client whose server knows that
/// plex.tv key for every person (null: knows none). Left out, the client is a plain [MediaServerClient].
Future<_ActorHarness> _createHarness(
  List<MediaItem> items, {
  required MediaBackend backend,
  Object? plexPersonTagKey = _noPlexClient,
}) async {
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

  final cache = backend == MediaBackend.plex ? PlexApiCache.instance : JellyfinApiCache.instance;
  final client = identical(plexPersonTagKey, _noPlexClient)
      ? _EnrichmentTestClient(items, backend, cache)
      : _PlexEnrichmentTestClient(items, backend, cache, plexPersonTagKey as String?);
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
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: child),
        ),
      ),
    );
  }
}

/// Backend-parameterized double for `MediaServerClient`. Deliberately omits
/// an `OfflineModeProvider` from the harness above (like the TV test's
/// harness) so these tests also exercise `_readOffline`'s
/// provider-not-found guard for free.
class _EnrichmentTestClient implements MediaServerClient {
  final List<MediaItem> items;
  final MediaBackend _backend;
  final ApiCache _cache;

  _EnrichmentTestClient(this.items, this._backend, this._cache);

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  MediaBackend get backend => _backend;

  @override
  ServerCapabilities get capabilities =>
      _backend == MediaBackend.plex ? ServerCapabilities.plex : ServerCapabilities.jellyfin;

  @override
  ApiCache get cache => _cache;

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
  Future<MediaItem?> fetchItem(String id) async => null;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const Object _noPlexClient = Object();

/// A Plex client double whose server answers the person-key lookup with [tagKey].
class _PlexEnrichmentTestClient extends _EnrichmentTestClient implements PlexClient {
  final String? tagKey;

  _PlexEnrichmentTestClient(super.items, super.backend, super.cache, this.tagKey);

  @override
  PlexProfileScopeId get profileScopeId => buildPlexProfileScopeId(serverId: serverId, profileId: 'profile-1');

  @override
  Future<String?> fetchPersonTagKey(String personId, {AbortController? abort}) async => tagKey;

  /// The page's character captions: none needed here.
  @override
  Future<List<MediaItem>> fetchItemsByIds(List<String> ids) async => const [];
}
