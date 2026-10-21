import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/episode_card.dart';
import 'package:provider/provider.dart';

import '../screens/episode_detail_test_support.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
  });

  testWidgets('tapping the title fires onTitleTap, not onTap (pointer mode)', (tester) async {
    var played = 0;
    var details = 0;
    final ep = fakeEpisode(title: 'Tap Me');

    await _pumpEpisodeCard(tester, ep, onTap: () => played++, onTitleTap: () => details++);

    await tester.tap(find.text('1. Tap Me'));
    await tester.pump();

    expect(details, 1);
    expect(played, 0);
  });

  testWidgets('tapping the card body still fires onTap when onTitleTap is set', (tester) async {
    var played = 0;
    var details = 0;
    final ep = fakeEpisode(title: 'Tap Me');

    await _pumpEpisodeCard(tester, ep, onTap: () => played++, onTitleTap: () => details++);

    // Tap inside the thumbnail region (top-left of the card row) — well away
    // from the title text — to confirm the row's own onTap still fires.
    final cardTopLeft = tester.getTopLeft(find.byKey(Key(ep.id)));
    await tester.tapAt(cardTopLeft + const Offset(20, 20));
    await tester.pump();

    expect(played, 1);
    expect(details, 0);
  });
}

Future<void> _pumpEpisodeCard(
  WidgetTester tester,
  MediaItem episode, {
  required VoidCallback onTap,
  VoidCallback? onTitleTap,
}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  PlexApiCache.initialize(db);
  JellyfinApiCache.initialize(db);
  final downloadManager = DownloadManagerService(
    database: db,
    storageService: DownloadStorageService.instance,
    clientResolver: (serverId, {clientScopeId}) => null,
  );
  downloadManager.recoveryFuture = Future<void>.value();
  final downloadProvider = DownloadProvider.forTesting(downloadManager: downloadManager, database: db);
  await downloadProvider.ensureInitialized();
  addTearDown(() async {
    downloadProvider.dispose();
    downloadManager.dispose();
    await db.close();
  });

  await tester.pumpWidget(
    TranslationProvider(
      child: ChangeNotifierProvider<DownloadProvider>.value(
        value: downloadProvider,
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: EpisodeCard(episode: episode, isOffline: true, onTap: onTap, onTitleTap: onTitleTap),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
