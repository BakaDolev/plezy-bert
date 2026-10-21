import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/enrichment/person_online_page.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/person_credit_strip.dart';

import '../test_helpers/media_items.dart';

/// The TV D-pad contract for the actor page's credit rails (S16-actor-dpad):
/// Select opens an owned credit (inert when non-owned), Left/Right move the
/// highlight, and Up/Down leave the strip for the neighbouring section.
void main() {
  final owned = const PersonCredit(title: 'Owned Movie', ratingKey: 'rk-owned', year: 2020);
  final notOwned = const PersonCredit(title: 'Online Only', ratingKey: 'rk-online', year: 2021);
  final ownedMatch = testMediaItem(
    id: 'lib-1',
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Owned Movie',
    serverId: 'server_1',
  );

  Future<PersonCreditStripState> pump(
    WidgetTester tester, {
    required void Function(PersonCredit, MediaItem?) onOpen,
    VoidCallback? onUp,
    VoidCallback? onDown,
  }) async {
    final key = GlobalKey<PersonCreditStripState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 960,
              child: PersonCreditStrip(
                key: key,
                title: 'Known For',
                credits: [owned, notOwned],
                libraryMatchFor: (c) => c.ratingKey == owned.ratingKey ? ownedMatch : null,
                onOpen: onOpen,
                onNavigateUp: onUp,
                onNavigateDown: onDown,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return key.currentState!;
  }

  testWidgets('renders its bundled title so it can never scroll off alone', (tester) async {
    await pump(tester, onOpen: (_, _) {});
    expect(find.text('Known For'), findsOneWidget);
    expect(find.text('Owned Movie'), findsOneWidget);
    expect(find.text('Online Only'), findsOneWidget);
  });

  testWidgets('Select opens the focused credit with its library match; Right then Select gives the next', (
    tester,
  ) async {
    final opened = <({String title, String? matchId})>[];
    final state = await pump(tester, onOpen: (c, m) => opened.add((title: c.title, matchId: m?.id)));

    state.requestFocus();
    await tester.pump();

    // Select on the first (owned) credit → opens it WITH its library match.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, [(title: 'Owned Movie', matchId: 'lib-1')]);

    // Right moves the highlight; Select on the second (online-only) credit
    // reports it with a NULL match (inert — no local item to open).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened.last, (title: 'Online Only', matchId: null));
  });

  testWidgets('Up and Down leave the strip via the section callbacks', (tester) async {
    var ups = 0;
    var downs = 0;
    final state = await pump(tester, onOpen: (_, _) {}, onUp: () => ups++, onDown: () => downs++);

    state.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(downs, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(ups, 1);
  });
}
