import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/enrichment/actor_info.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/actor_hero_header.dart';
import 'package:plezy/widgets/collapsible_text.dart';
import 'package:plezy/widgets/media_card.dart' show SkeletonLoader;
import 'package:plezy/widgets/placeholder_container.dart';
import 'package:plezy/widgets/rasterized_gradient.dart';

// Real app theme (not a bare MaterialApp) so MonoTokens — used for the
// portrait card's corner radius — is present on the tree, matching how
// ActorHeroHeader is actually themed in the app.
Widget _wrap(Widget child) => MaterialApp(
  theme: monoTheme(dark: true),
  home: Scaffold(body: child),
);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('portrait present shows the actor name and a portrait image, with no blurred backdrop layer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ActorHeroHeader(
          actorName: 'Jane Doe',
          portraitPath: 'https://example.invalid/actor-portrait.jpg',
          titleCount: 3,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    // The old design's blurred-portrait-as-artwork backdrop and its scrim
    // are gone entirely — never reintroduced as widgets in the tree.
    expect(find.byType(RasterizedGradient), findsNothing);
    expect(find.byType(PlaceholderContainer), findsNothing);
  });

  testWidgets('missing portrait falls back to the person icon without crashing, and stays backdrop-free', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const ActorHeroHeader(actorName: 'Jane Doe', portraitPath: null, titleCount: 0)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.byIcon(Symbols.person_rounded), findsOneWidget);
    expect(find.byType(RasterizedGradient), findsNothing);
    expect(find.byType(PlaceholderContainer), findsNothing);
  });

  testWidgets('enrichment renders the occupation line, a born-died range, and the bio', (tester) async {
    const info = ActorInfo(
      bornYear: 1975,
      diedYear: 2020,
      occupations: ['Actor', 'Director'],
      bio: 'A celebrated performer known for many memorable roles.',
    );
    await tester.pumpWidget(_wrap(const ActorHeroHeader(actorName: 'Jane Doe', titleCount: 5, enrichment: info)));
    await tester.pump();

    expect(find.text('Actor, Director'), findsOneWidget);
    expect(find.text('1975–2020'), findsOneWidget);
    expect(find.textContaining('A celebrated performer'), findsWidgets);
  });

  testWidgets('an alive person (no death year) shows "Born {year}" only, never a dash range', (tester) async {
    const info = ActorInfo(bornYear: 1990);
    await tester.pumpWidget(_wrap(const ActorHeroHeader(actorName: 'Jane Doe', titleCount: 1, enrichment: info)));
    await tester.pump();

    expect(find.text('Born 1990'), findsOneWidget);
    expect(find.textContaining('–'), findsNothing);
    expect(find.textContaining('—'), findsNothing);
  });

  testWidgets('loading enrichment with no data yet shows occupation/born and bio skeletons', (tester) async {
    await tester.pumpWidget(
      _wrap(const ActorHeroHeader(actorName: 'Jane Doe', titleCount: 2, isEnrichmentLoading: true)),
    );
    await tester.pump();

    expect(find.byType(SkeletonLoader), findsWidgets);
    expect(find.byType(CollapsibleText), findsNothing);
  });

  testWidgets('idle enrichment (not loading, no data) shows no bio box and no skeletons at all', (tester) async {
    await tester.pumpWidget(_wrap(const ActorHeroHeader(actorName: 'Jane Doe', titleCount: 2)));
    await tester.pump();

    expect(find.byType(SkeletonLoader), findsNothing);
    expect(find.byType(CollapsibleText), findsNothing);
  });

  testWidgets('characterName and titleCount are accepted but no longer rendered (Plex header has neither)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const ActorHeroHeader(actorName: 'Jane Doe', characterName: 'Danny Tanner', titleCount: 4)),
    );
    await tester.pump();

    expect(find.textContaining('Danny Tanner'), findsNothing);
    expect(find.textContaining('4'), findsNothing);
  });

  testWidgets('narrow width stacks the portrait above the text without overflowing', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const info = ActorInfo(
      bornYear: 1975,
      occupations: ['Actor', 'Producer', 'Director'],
      bio: 'A celebrated performer known for many memorable roles across film and television.',
    );
    await tester.pumpWidget(
      _wrap(const ActorHeroHeader(actorName: 'Jane Doe', titleCount: 5, enrichment: info, portraitPath: null)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Jane Doe'), findsOneWidget);
  });

  // Age is computed against the current date, so derive the expectation the
  // same way the widget does rather than hard-coding a value that rots.
  int expectedAge(int year, int month, int day) {
    final now = DateTime.now();
    final hadBirthday = now.month > month || (now.month == month && now.day >= day);
    return now.year - year - (hadBirthday ? 0 : 1);
  }

  testWidgets('Plex profile born line: full date, computed age, and birthplace', (tester) async {
    final age = expectedAge(1969, 7, 30);
    await tester.pumpWidget(
      _wrap(
        const ActorHeroHeader(
          actorName: 'Simon Baker',
          titleCount: 3,
          bornOn: '1969-07-30',
          birthPlace: 'Launceston, Tasmania, Australia',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('July 30, 1969 · $age · Launceston, Tasmania, Australia'), findsOneWidget);
  });

  testWidgets('born line degrades gracefully when the birthplace is absent (no trailing separator)', (tester) async {
    final age = expectedAge(1969, 7, 30);
    await tester.pumpWidget(
      _wrap(const ActorHeroHeader(actorName: 'Simon Baker', titleCount: 1, bornOn: '1969-07-30')),
    );
    await tester.pump();

    expect(find.text('July 30, 1969 · $age'), findsOneWidget);
    // Never the year-only fallback when the full date is present.
    expect(find.text('Born 1969'), findsNothing);
  });

  testWidgets('a malformed born date falls back to the year-only line, never a wrong value', (tester) async {
    // No parseable date, but enrichment still carries a birth year.
    await tester.pumpWidget(
      _wrap(
        const ActorHeroHeader(
          actorName: 'Jane Doe',
          titleCount: 1,
          bornOn: 'unknown',
          enrichment: ActorInfo(bornYear: 1990),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Born 1990'), findsOneWidget);
  });

  testWidgets('Instagram URL renders a tappable @handle link', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const ActorHeroHeader(
          actorName: 'Simon Baker',
          titleCount: 1,
          instagramUrl: 'https://www.instagram.com/simonbaker/',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('@simonbaker'), findsOneWidget);
    expect(find.byIcon(Symbols.open_in_new_rounded), findsOneWidget);
  });

  testWidgets('TV hero stays compact: no Instagram line, a two-line bio preview, within its height budget', (
    tester,
  ) async {
    // The TV hero is pinned above the scrolling sections of a 960x540 screen,
    // so every row it grows costs the grid/filmography below the same height.
    const bio =
        'A celebrated performer known for many memorable roles across film and '
        'television, with a career spanning several decades and numerous awards, '
        'nominations, and a long list of acclaimed stage productions besides.';
    const tvHeroHeightBudget = 200.0;
    final bioNode = FocusNode(debugLabel: 'test_actor_bio');
    addTearDown(bioNode.dispose);

    await tester.pumpWidget(
      _wrap(
        SingleChildScrollView(
          child: SizedBox(
            width: 960,
            child: ActorHeroHeader(
              actorName: 'Simon Baker',
              titleCount: 1,
              enrichment: const ActorInfo(bio: bio, occupations: ['actor', 'producer'], bornYear: 1969),
              bornOn: '1969-07-30',
              birthPlace: 'Launceston, Tasmania, Australia',
              instagramUrl: 'https://www.instagram.com/simonbaker/',
              isTv: true,
              bioFocusNode: bioNode,
              onBioReadMore: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // A TV has no browser to open the link, and it would cost the hero a row.
    expect(find.text('@simonbaker'), findsNothing);
    expect(tester.widget<Text>(find.text(bio)).maxLines, 2);
    expect(tester.getSize(find.byType(ActorHeroHeader)).height, lessThanOrEqualTo(tvHeroHeightBudget));
  });

  testWidgets('no Plex profile facts and no enrichment: no born line, no Instagram, no crash', (tester) async {
    await tester.pumpWidget(_wrap(const ActorHeroHeader(actorName: 'Simon Baker', titleCount: 0)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('·'), findsNothing);
    expect(find.byIcon(Symbols.open_in_new_rounded), findsNothing);
  });
}
