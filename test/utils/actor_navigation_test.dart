import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_role.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/actor_media_screen.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/actor_navigation.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';

MediaItem _source() =>
    MediaItem(id: 'ep1', backend: MediaBackend.plex, kind: MediaKind.episode, serverId: 'srv1', serverName: 'Server');

/// Minimal fake — enough for [ActorMediaScreen] to mount and load without
/// touching a real server. serverId/serverName/backend/close are concrete
/// because [testMultiServer] reads/calls them synchronously during client
/// registration and manager teardown; fetchPersonMediaPage is concrete too
/// since the screen awaits it directly on mount. Everything else falls
/// through noSuchMethod (unused by this screen).
class _FakeActorClient implements MediaServerClient {
  _FakeActorClient({ServerId? serverId}) : serverId = serverId ?? ServerId('srv1');

  @override
  final ServerId serverId;

  @override
  final String? serverName = 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  void close() {}

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('pushes ActorMediaScreen for a role with an id', (tester) async {
    // ActorMediaScreen resolves its MediaServerClient from MultiServerProvider
    // at build time, so the pushed route needs a registered client for 'srv1'.
    final provider = testMultiServer(clients: [_FakeActorClient(serverId: ServerId('srv1'))]).provider;
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>.value(
        value: provider,
        child: MaterialApp(
          navigatorKey: nav,
          // The full actor page reads the app's theme tokens.
          theme: monoTheme(dark: true),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => navigateToActorMedia(
                context,
                const MediaRole(id: 'p1', tag: 'Jane Doe', role: 'Herself', thumbPath: null, tagKey: 'person-key-1'),
                _source(),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    final screen = tester.widget<ActorMediaScreen>(find.byType(ActorMediaScreen));
    expect(screen.personId, 'p1');
    // The global person key is the actor page's bridge to the online person
    // page (bio, Known For); dropping it leaves a library-only page.
    expect(screen.personTagKey, 'person-key-1');
  });

  testWidgets('does nothing when role id is null', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => navigateToActorMedia(
              context,
              const MediaRole(id: null, tag: 'No Id', role: null, thumbPath: null),
              _source(),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(ActorMediaScreen), findsNothing);
  });
}
