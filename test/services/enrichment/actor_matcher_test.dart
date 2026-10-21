import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/enrichment/actor_info.dart';
import 'package:plezy/services/enrichment/actor_matcher.dart';

/// A candidate that satisfies every acceptance gate — including the
/// exact-name gate against the `'Jane Doe'` name every test below queries
/// with — so each test overrides just the field under test and a failure
/// isolates a single gate (spec §6a).
WikidataCandidate _acceptableCandidate({
  String qid = 'Q1',
  bool isHuman = true,
  Set<String> occupationQids = const {'Q33999'},
  bool hasEnwikiSitelink = true,
  String description = 'American actor',
  String label = 'Jane Doe',
  List<String> aliases = const [],
}) {
  return WikidataCandidate(
    qid: qid,
    isHuman: isHuman,
    occupationQids: occupationQids,
    hasEnwikiSitelink: hasEnwikiSitelink,
    description: description,
    label: label,
    aliases: aliases,
  );
}

void main() {
  group('kActingOccupations', () {
    test('holds the five acting-occupation QIDs from spec §6a', () {
      expect(kActingOccupations, {'Q33999', 'Q10800557', 'Q10798782', 'Q2405480', 'Q2259451'});
    });
  });

  group('selectActorCandidate', () {
    test('unique acceptable candidate returns its qid', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [_acceptableCandidate(qid: 'Q42')],
      );
      expect(qid, 'Q42');
    });

    test('two acceptable candidates returns null (ambiguous)', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [
          _acceptableCandidate(qid: 'Q1'),
          _acceptableCandidate(qid: 'Q2'),
        ],
      );
      expect(qid, isNull);
    });

    test('zero candidates returns null', () {
      final qid = selectActorCandidate(name: 'Jane Doe', candidates: const []);
      expect(qid, isNull);
    });

    test('one candidate but not human returns null', () {
      final qid = selectActorCandidate(name: 'Jane Doe', candidates: [_acceptableCandidate(isHuman: false)]);
      expect(qid, isNull);
    });

    test('one human but no acting occupation returns null', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        // Q82955 = politician: human, real occupation QID, just not an acting one.
        candidates: [
          _acceptableCandidate(occupationQids: {'Q82955'}),
        ],
      );
      expect(qid, isNull);
    });

    test('acting occupation but no enwiki sitelink returns null', () {
      final qid = selectActorCandidate(name: 'Jane Doe', candidates: [_acceptableCandidate(hasEnwikiSitelink: false)]);
      expect(qid, isNull);
    });

    test('description lacks an acting term returns null (secondary gate)', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [_acceptableCandidate(description: 'American politician and lawyer')],
      );
      expect(qid, isNull);
    });

    test('secondary gate is case-insensitive', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [_acceptableCandidate(qid: 'Q7', description: 'AMERICAN ACTOR')],
      );
      expect(qid, 'Q7');
    });

    test('description word-boundary gate rejects "factor"/"factory" (not the "actor" substring)', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [_acceptableCandidate(description: 'Owner of a toy factory and risk factor analyst')],
      );
      expect(qid, isNull);
    });

    // --- Exact-name gate (controller addendum) ---

    test('exact label match (case-insensitive, whitespace-trimmed) accepts', () {
      final qid = selectActorCandidate(
        name: '  jane doe  ',
        candidates: [_acceptableCandidate(qid: 'Q9', label: 'Jane Doe')],
      );
      expect(qid, 'Q9');
    });

    test('exact alias match accepts even when the label differs', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [
          _acceptableCandidate(qid: 'Q10', label: 'Jane A. Doe', aliases: ['Jane Doe', 'J. Doe']),
        ],
      );
      expect(qid, 'Q10');
    });

    test('near-miss/prefix label with every other gate passing is rejected (no exact name match)', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [_acceptableCandidate(label: 'Jane Doe Jr.', aliases: const [])],
      );
      expect(qid, isNull);
    });

    test('two exact-name matches returns null (ambiguous even though both are exact)', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [
          _acceptableCandidate(qid: 'Q1', label: 'Jane Doe'),
          _acceptableCandidate(qid: 'Q2', label: 'Jane Doe'),
        ],
      );
      expect(qid, isNull);
    });

    test('otherwise-acceptable candidate whose only match is a non-exact alias is rejected', () {
      final qid = selectActorCandidate(
        name: 'Jane Doe',
        candidates: [
          _acceptableCandidate(label: 'Someone Else', aliases: ['Jane Doelittle']),
        ],
      );
      expect(qid, isNull);
    });
  });

  group('ActorInfo', () {
    test('toJson/fromJson round-trips every field through real JSON', () {
      const info = ActorInfo(
        qid: 'Q42',
        bornYear: 1952,
        diedYear: 2001,
        occupations: ['Actor', 'Voice actor'],
        bio: 'A short bio.',
        enwikiTitle: 'Jane Doe',
      );

      final roundTripped = ActorInfo.fromJson(jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>);

      expect(roundTripped.qid, info.qid);
      expect(roundTripped.bornYear, info.bornYear);
      expect(roundTripped.diedYear, info.diedYear);
      expect(roundTripped.occupations, info.occupations);
      expect(roundTripped.bio, info.bio);
      expect(roundTripped.enwikiTitle, info.enwikiTitle);
    });

    test('fromJson tolerates a minimal payload with only qid', () {
      final info = ActorInfo.fromJson({'qid': 'Q42'});

      expect(info.qid, 'Q42');
      expect(info.bornYear, isNull);
      expect(info.diedYear, isNull);
      expect(info.occupations, isEmpty);
      expect(info.bio, isNull);
      expect(info.enwikiTitle, isNull);
    });
  });
}
