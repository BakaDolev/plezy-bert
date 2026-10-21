import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/episode_detail_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:provider/provider.dart';

import '../screens/episode_detail_test_support.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';

/// Counts pushed routes so the test can assert exactly one navigation
/// happened. Mirrors the helper in media_navigation_helper_episode_test.dart.
class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('tapping the episode title on a card opens the episode detail page, not playback', (tester) async {
    final episode = testMediaItem(
      id: 'ep1',
      backend: MediaBackend.plex,
      kind: MediaKind.episode,
      title: 'Some Episode',
      parentId: 'season_2',
      parentIndex: 2,
      index: 11,
      grandparentId: 'show_1',
      grandparentTitle: 'Some Show',
      serverId: 'srv1',
      serverName: 'Server',
    );
    final provider = testMultiServer(clients: [FakeEpisodeClient(item: episode)]).provider;
    final observer = _RecordingNavigatorObserver();

    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider.value(
          value: provider,
          child: withProfileNavigationScope(
            child: MaterialApp(
              theme: monoTheme(dark: true),
              navigatorObservers: [observer],
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 420,
                    height: 180,
                    child: MediaCard(item: episode, viewModeOverride: ViewMode.list),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final pushesBeforeTap = observer.pushCount;
    await tester.tap(find.text('Some Episode'));
    await tester.pumpAndSettle();

    expect(observer.pushCount, pushesBeforeTap + 1, reason: 'tapping the episode title should push exactly one route');
    expect(find.byType(EpisodeDetailScreen), findsOneWidget);
  });
}
