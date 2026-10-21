import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/enrichment/person_online_page.dart';

/// Fixtures mirror the real Discover responses captured 2026-08-23 (Simon
/// Baker) — see docs/design/2026-08-23-plex-discover-person-api.md.
Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('PersonOnlinePageParser.parseProfile', () {
    final root = _json('''
    {"MediaContainer":{"Metadata":[{
      "title":"Simon Baker",
      "summary":"Simon Baker (born July 30, 1969) is an Australian actor and director.",
      "bornAt":"1969-07-30",
      "birthPlace":"Launceston, Tasmania, Australia",
      "thumb":"https://metadata-static.plex.tv/b/people/portrait.jpg",
      "External":[{"source":"instagram","url":"https://www.instagram.com/snappytoes"}],
      "CreditType":[
        {"type":"actor","count":597,"title":"Actor"},
        {"type":"producer","count":68,"title":"Producer"},
        {"type":"director","count":11,"title":"Director"},
        {"type":"camera","count":1,"title":"camera"},
        {"type":"writer","count":1,"title":"Writer"}
      ]
    }]}}''');

    test('pulls bio, birth facts, portrait and the Instagram link', () {
      final p = PersonOnlinePageParser.parseProfile(root);
      expect(p.bio, startsWith('Simon Baker (born'));
      expect(p.bornAt, '1969-07-30');
      expect(p.birthPlace, 'Launceston, Tasmania, Australia');
      expect(p.thumbUrl, 'https://metadata-static.plex.tv/b/people/portrait.jpg');
      expect(p.instagramUrl, 'https://www.instagram.com/snappytoes');
    });

    test('occupations = the two highest-count credit types, capitalised', () {
      // 597 actor + 68 producer win over director/camera/writer; matches Plex's
      // "Actor, Producer" header line.
      expect(PersonOnlinePageParser.parseProfile(root).occupations, ['Actor', 'Producer']);
    });

    test('bornYear extracts the four-digit year', () {
      final page = PersonOnlinePage(bornAt: PersonOnlinePageParser.parseProfile(root).bornAt);
      expect(page.bornYear, 1969);
    });

    test('an empty container yields all-null profile with no occupations', () {
      final p = PersonOnlinePageParser.parseProfile(_json('{"MediaContainer":{}}'));
      expect(p.bio, isNull);
      expect(p.bornAt, isNull);
      expect(p.instagramUrl, isNull);
      expect(p.occupations, isEmpty);
    });
  });

  group('PersonOnlinePageParser.parseCredits', () {
    final root = _json('''
    {"MediaContainer":{"CreditGroup":[
      {"title":"Actor","type":"actor","Credit":[
        {"order":1,"role":"Cast","Metadata":{"ratingKey":"a1","title":"Klara and the Sun","type":"movie","year":2026,"thumb":"https://x/klara.jpg"}},
        {"order":4,"role":"Benton Wesley","Metadata":{"ratingKey":"a2","title":"Scarpetta","type":"show","year":2026,"thumb":"https://x/scarpetta.jpg"}}
      ]},
      {"title":"Producer","type":"producer","Credit":[
        {"order":1,"role":"","Metadata":{"ratingKey":"p1","title":"Breath","type":"movie","year":2017}}
      ]}
    ]}}''');

    test('one group per role type, in order', () {
      final groups = PersonOnlinePageParser.parseCredits(root);
      expect(groups.map((g) => g.label), ['Actor', 'Producer']);
      expect(groups.map((g) => g.type), ['actor', 'producer']);
    });

    test('each credit carries character, year, media type and poster', () {
      final actor = PersonOnlinePageParser.parseCredits(root).first;
      expect(actor.credits, hasLength(2));
      expect(actor.credits[1].title, 'Scarpetta');
      expect(actor.credits[1].character, 'Benton Wesley');
      expect(actor.credits[1].year, 2026);
      expect(actor.credits[1].mediaType, 'show');
      expect(actor.credits[1].posterUrl, 'https://x/scarpetta.jpg');
      expect(actor.credits[1].ratingKey, 'a2');
    });

    test('keeps the literal "Cast" role but collapses a blank role to null', () {
      final groups = PersonOnlinePageParser.parseCredits(root);
      expect(groups[0].credits[0].character, 'Cast');
      expect(groups[1].credits.single.character, isNull);
    });

    test('empty container yields no groups', () {
      expect(PersonOnlinePageParser.parseCredits(_json('{"MediaContainer":{}}')), isEmpty);
    });
  });

  group('PersonOnlinePageParser.parseKnownFor', () {
    final root = _json('''
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"k1","title":"The Mentalist","type":"show","year":2008,"thumb":"https://x/m.jpg","parentTitle":"Patrick Jane / Director / Producer"},
      {"ratingKey":"k2","title":"The Devil Wears Prada","type":"movie","year":2006,"parentTitle":"Christian Thompson"}
    ]}}''');

    test('reads the character from parentTitle', () {
      final items = PersonOnlinePageParser.parseKnownFor(root);
      expect(items, hasLength(2));
      expect(items[0].title, 'The Mentalist');
      expect(items[0].character, 'Patrick Jane / Director / Producer');
      expect(items[0].year, 2008);
      expect(items[0].mediaType, 'show');
      expect(items[1].character, 'Christian Thompson');
    });

    test('empty container yields no items', () {
      expect(PersonOnlinePageParser.parseKnownFor(_json('{"MediaContainer":{}}')), isEmpty);
    });
  });

  group('PersonOnlinePage.hasContent', () {
    test('true when known-for or credits or bio are present, false when bare', () {
      expect(const PersonOnlinePage().hasContent, isFalse);
      expect(const PersonOnlinePage(bio: 'x').hasContent, isTrue);
      expect(
        const PersonOnlinePage(knownFor: [PersonCredit(title: 'X')]).hasContent,
        isTrue,
      );
      expect(
        const PersonOnlinePage(creditGroups: [PersonCreditGroup(label: 'Actor', type: 'actor', credits: [])]).hasContent,
        isFalse,
      );
    });
  });
}
