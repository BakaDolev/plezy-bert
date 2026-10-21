import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/enrichment/person_online_page.dart';
import 'package:plezy/widgets/person_credit_card.dart';

/// The actor page's "Known For" poster card. Non-owned online titles render
/// inert; a title in your library is given an [onTap] (opening the local item)
/// and opts out of the surrounding [SelectionArea] so the tap fires cleanly —
/// mirroring how the filmography rows link owned titles and leave the rest
/// plain.
void main() {
  // posterUrl null keeps the card off the network (placeholder poster).
  const credit = PersonCredit(title: 'The Mentalist', year: 2008, character: 'Patrick Jane', mediaType: 'show');

  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  );

  testWidgets('renders the title, character, and year', (tester) async {
    await tester.pumpWidget(wrap(const PersonCreditCard(credit: credit)));
    await tester.pump();

    expect(find.text('The Mentalist'), findsOneWidget);
    expect(find.text('Patrick Jane'), findsOneWidget);
    expect(find.text('2008'), findsOneWidget);
  });

  testWidgets('a non-owned credit (no onTap) is inert — no selection opt-out wrapper', (tester) async {
    await tester.pumpWidget(wrap(const PersonCreditCard(credit: credit)));
    await tester.pump();

    // The SelectionContainer.disabled + tap wrapper is added only when owned.
    expect(find.byType(SelectionContainer), findsNothing);
  });

  testWidgets('an owned credit (onTap) fires the callback on tap and opts out of selection', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(PersonCreditCard(credit: credit, onTap: () => taps++)));
    await tester.pump();

    // Opts out of the ambient SelectionArea so the tap is not swallowed as a
    // text drag.
    expect(find.byType(SelectionContainer), findsOneWidget);

    await tester.tap(find.text('The Mentalist'));
    await tester.pump();
    expect(taps, 1);
  });
}
