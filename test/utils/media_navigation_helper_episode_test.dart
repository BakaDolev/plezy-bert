import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/episode_detail_screen.dart';
import 'package:plezy/utils/media_navigation_helper.dart';
import 'package:provider/provider.dart';
import '../screens/episode_detail_test_support.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';

/// Counts pushed routes so tests can assert navigation did (or did not)
/// happen without mounting/settling the pushed screen. Mirrors the helper in
/// episode_detail_screen_test.dart.
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
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('navigateToEpisodeDetail opens EpisodeDetailScreen for an episode', (tester) async {
    final ep = fakeEpisode(id: 'ep1', title: 'Details Me');
    final provider = testMultiServer(clients: [FakeEpisodeClient(item: ep)]).provider;
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: withProfileNavigationScope(
              child: Builder(
                builder: (context) =>
                    ElevatedButton(onPressed: () => navigateToEpisodeDetail(context, ep), child: const Text('go')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(EpisodeDetailScreen), findsOneWidget);
  });

  // Regression test for the Task 8 over-broad intercept: navigateToMediaItemDetails
  // must route an episode to its parent show/season page, not the single-episode
  // page. MediaCard's show-name title and "S2" season link both call
  // navigateToMediaItemDetails(context, episode) and rely on this.
  testWidgets('navigateToMediaItemDetails opens the show/season page for an episode, not EpisodeDetailScreen', (
    tester,
  ) async {
    // The pushed target is MediaDetailScreen, which reads ProfileNavigationScope
    // in didChangeDependencies — scoping it inside `home:` only covers the FIRST
    // route on the Navigator, so this test wraps MaterialApp itself instead
    // (same fix as episode_detail_screen_test.dart's "Go to show button"
    // test), making the scope available to this pushed route too.
    final ep = fakeEpisode(id: 'ep1', title: 'Details Me');
    final provider = testMultiServer(clients: [FakeEpisodeClient(item: ep)]).provider;
    final observer = _RecordingNavigatorObserver();
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider.value(
          value: provider,
          child: withProfileNavigationScope(
            child: MaterialApp(
              navigatorObservers: [observer],
              home: Builder(
                builder: (context) =>
                    ElevatedButton(onPressed: () => navigateToMediaItemDetails(context, ep), child: const Text('go')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Deliberately no tester.pump() after the tap: Navigator.push notifies
    // observers synchronously as part of the push call, before the pushed
    // MediaDetailScreen's element tree is ever mounted/built — pumping here
    // would build its real hero header, which reads several more
    // MediaServerClient members FakeEpisodeClient doesn't stub (see the
    // identical note in episode_detail_screen_test.dart).
    final pushesBeforeTap = observer.pushCount;
    await tester.tap(find.text('go'));

    expect(observer.pushCount, greaterThan(pushesBeforeTap), reason: 'navigateToMediaItemDetails should push a route');
    expect(find.byType(EpisodeDetailScreen), findsNothing);
  });
}
