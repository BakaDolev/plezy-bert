import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/enrichment/person_online_page.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/person_filmography_list.dart';

import '../test_helpers/media_items.dart';

/// The TV D-pad contract for the actor page's filmography LIST (S17-actor-tv-
/// filmo-list / S16-actor-dpad): the desktop-style role-tabbed list, made
/// 10-foot navigable — Up/Down move rows (leaving at the ends via the section
/// callbacks), Left/Right switch role tabs, and Select opens an owned row
/// (inert when the title isn't in your library).
void main() {
  const owned = PersonCredit(title: 'Owned Movie', ratingKey: 'rk-owned', year: 2020);
  const notOwned = PersonCredit(title: 'Online Only', ratingKey: 'rk-online', year: 2021);
  const produced = PersonCredit(title: 'Produced Film', ratingKey: 'rk-prod', year: 2019);

  final ownedMatch = testMediaItem(
    id: 'lib-1',
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: 'Owned Movie',
    serverId: 'server_1',
  );

  final groups = <PersonCreditGroup>[
    const PersonCreditGroup(label: 'Actor', type: 'actor', credits: [owned, notOwned]),
    const PersonCreditGroup(label: 'Producer', type: 'producer', credits: [produced]),
  ];

  Future<PersonFilmographyListState> pump(
    WidgetTester tester, {
    required void Function(PersonCredit, MediaItem?) onOpen,
    VoidCallback? onUp,
    VoidCallback? onDown,
  }) async {
    final key = GlobalKey<PersonFilmographyListState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 960,
              child: PersonFilmographyList(
                key: key,
                title: 'Filmography',
                groups: groups,
                libraryMatchFor: (c) => c.ratingKey == owned.ratingKey ? ownedMatch : null,
                onOpen: onOpen,
                onServerLabel: 'On My Server',
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

  testWidgets('given a height, the unit fills exactly that height and a long list scrolls inside it', (tester) async {
    // The TV actor page hands the list its viewport height so the heading,
    // tabs and every visible row fit on screen under the pinned hero.
    const unitHeight = 300.0;
    final manyCredits = [
      for (var i = 0; i < 20; i++) PersonCredit(title: 'Credit $i', ratingKey: 'rk-$i', year: 2000 + i),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 960,
              child: PersonFilmographyList(
                title: 'Filmography',
                groups: [
                  PersonCreditGroup(label: 'Actor', type: 'actor', credits: manyCredits),
                  const PersonCreditGroup(label: 'Producer', type: 'producer', credits: [produced]),
                ],
                libraryMatchFor: (_) => null,
                onOpen: (_, _) {},
                height: unitHeight,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(PersonFilmographyList)).height, unitHeight);
    expect(find.text('Credit 0'), findsOneWidget);
    expect(find.text('Credit 19'), findsNothing);
  });

  testWidgets('renders the heading, role tabs, and the active group rows (with the On-server tag)', (tester) async {
    await pump(tester, onOpen: (_, _) {});
    expect(find.text('Filmography'), findsOneWidget);
    expect(find.text('Actor (2)'), findsOneWidget);
    expect(find.text('Producer (1)'), findsOneWidget);
    // Active tab is the first group (Actor): its rows show, the other group's don't.
    expect(find.text('Owned Movie'), findsOneWidget);
    expect(find.text('Online Only'), findsOneWidget);
    expect(find.text('Produced Film'), findsNothing);
    // Owned rows carry the "On {server}" tag; non-owned don't.
    expect(find.text('On My Server'), findsOneWidget);
  });

  testWidgets('Select opens the focused row with its match; Down then Select gives the next (inert)', (tester) async {
    final opened = <({String title, String? matchId})>[];
    final state = await pump(tester, onOpen: (c, m) => opened.add((title: c.title, matchId: m?.id)));

    state.requestFocus();
    await tester.pump();

    // Select on the first (owned) row → opens it WITH its library match.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, [(title: 'Owned Movie', matchId: 'lib-1')]);

    // Down moves to the online-only row; Select reports a NULL match (inert).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened.last, (title: 'Online Only', matchId: null));
  });

  testWidgets('Up at the first row and Down past the last leave via the section callbacks', (tester) async {
    var ups = 0;
    var downs = 0;
    final state = await pump(tester, onOpen: (_, _) {}, onUp: () => ups++, onDown: () => downs++);

    state.requestFocus();
    await tester.pump();

    // At row 0, Up leaves upward (no internal row above).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(ups, 1);

    // Down to the last row (row 1), then Down again leaves downward.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(downs, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(downs, 1);
  });

  testWidgets('Left/Right switch role tabs and swap the visible rows', (tester) async {
    final state = await pump(tester, onOpen: (_, _) {});
    state.requestFocus();
    await tester.pump();

    // Right → the Producer group; its row shows, the Actor rows don't.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('Produced Film'), findsOneWidget);
    expect(find.text('Owned Movie'), findsNothing);

    // Left → back to the Actor group.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text('Owned Movie'), findsOneWidget);
    expect(find.text('Produced Film'), findsNothing);
  });
}
