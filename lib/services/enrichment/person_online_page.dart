/// Typed models for a person's online page on Plex's Discover provider
/// (`discover.provider.plex.tv/library/people/{tagKey}` + `/credits` +
/// `/person_known_for`). See `docs/design/2026-08-23-plex-discover-person-api.md`.
///
/// These back the actor page's Plex-matching sections — a rich profile header,
/// the "Known For" row, and the tabbed full filmography — none of which the
/// local library's per-person media list can provide.
library;

import '../../utils/json_utils.dart';

/// One title in a person's online filmography or "Known For" row.
class PersonCredit {
  /// Discover ratingKey (stable id on the metadata provider). Kept for future
  /// tap-through; not required to render.
  final String? ratingKey;
  final String title;
  final int? year;

  /// The character/role text as Plex reports it — `"Patrick Jane"`, the
  /// multi-role summary `"Patrick Jane / Director / Producer"` (Known For), or
  /// `"Cast"` when the credit is unnamed. Empty/blank is normalised to null.
  final String? character;

  /// `"movie"` or `"show"` (drives the caption's screen count and future nav).
  final String mediaType;

  /// Absolute poster URL, or null.
  final String? posterUrl;

  const PersonCredit({
    required this.title,
    this.ratingKey,
    this.year,
    this.character,
    this.mediaType = '',
    this.posterUrl,
  });
}

/// One filmography tab (Actor/Producer/Director/Writer/…) from `/credits`.
class PersonCreditGroup {
  /// Human label as Plex titles it (`"Actor"`).
  final String label;

  /// Machine type (`"actor"`).
  final String type;
  final List<PersonCredit> credits;

  const PersonCreditGroup({required this.label, required this.type, required this.credits});
}

/// A person's whole online page: profile facts + "Known For" + full filmography.
class PersonOnlinePage {
  final String? bio;

  /// ISO birth date as reported (`"1969-07-30"`); parse for display.
  final String? bornAt;
  final String? birthPlace;
  final String? thumbUrl;

  /// External profile link (Instagram), when present.
  final String? instagramUrl;

  /// Occupations derived from the credit-group labels present, in Plex's order
  /// (`["Actor", "Producer"]`) — the header's subtitle line.
  final List<String> occupations;

  final List<PersonCredit> knownFor;
  final List<PersonCreditGroup> creditGroups;

  const PersonOnlinePage({
    this.bio,
    this.bornAt,
    this.birthPlace,
    this.thumbUrl,
    this.instagramUrl,
    this.occupations = const [],
    this.knownFor = const [],
    this.creditGroups = const [],
  });

  /// True when nothing renderable came back — callers then keep the existing
  /// library-only / Wikidata-enriched page instead of showing empty sections.
  bool get hasContent => knownFor.isNotEmpty || creditGroups.any((g) => g.credits.isNotEmpty) || (bio?.isNotEmpty ?? false);

  /// The four-digit birth year, if [bornAt] holds one.
  int? get bornYear {
    final match = RegExp(r'^(\d{4})').firstMatch(bornAt ?? '');
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}

/// Parses the three Discover person responses (see the design doc) into the
/// models above. Pure and tolerant: unknown/missing fields degrade to null or
/// empty rather than throwing, so a partial or drifted response still renders
/// what it can.
class PersonOnlinePageParser {
  const PersonOnlinePageParser._();

  static Map<String, dynamic> _container(Map<String, dynamic>? root) =>
      firstFlexibleMap(root?['MediaContainer']) ?? const {};

  /// A blank/`"Cast"`-only role stays as text (Plex shows "as Cast"); only a
  /// truly empty value collapses to null.
  static String? _character(Object? role) {
    final s = (role ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  static PersonCredit _credit(Map<String, dynamic> metadata, {Object? role}) => PersonCredit(
    ratingKey: (metadata['ratingKey'] ?? metadata['guid'])?.toString(),
    title: stringOrEmpty(metadata['title']),
    year: flexibleInt(metadata['year']),
    character: _character(role),
    mediaType: stringOrEmpty(metadata['type']),
    posterUrl: (metadata['thumb'])?.toString(),
  );

  /// `/library/people/{key}` — profile facts + occupations (top credit types).
  static ({
    String? bio,
    String? bornAt,
    String? birthPlace,
    String? thumbUrl,
    String? instagramUrl,
    List<String> occupations,
  })
  parseProfile(Map<String, dynamic>? root) {
    final meta = firstFlexibleMap(_container(root)['Metadata']) ?? const {};

    String? instagram;
    for (final ext in flexibleMapList(meta['External'])) {
      if (stringOrEmpty(ext['source']).toLowerCase() == 'instagram') {
        instagram = ext['url']?.toString();
        break;
      }
    }

    // Occupations: the credit types with the most credits, Plex-style ("Actor,
    // Producer"). Capitalised (Plex reports "camera" lower-cased).
    final credits = flexibleMapList(meta['CreditType']).where((c) => (flexibleInt(c['count']) ?? 0) > 0).toList()
      ..sort((a, b) => (flexibleInt(b['count']) ?? 0).compareTo(flexibleInt(a['count']) ?? 0));
    final occupations = [
      for (final c in credits.take(2))
        if (stringOrEmpty(c['title']).isNotEmpty) _capitalize(stringOrEmpty(c['title'])),
    ];

    return (
      bio: (meta['summary'])?.toString(),
      bornAt: (meta['bornAt'])?.toString(),
      birthPlace: (meta['birthPlace'])?.toString(),
      thumbUrl: (meta['thumb'])?.toString(),
      instagramUrl: instagram,
      occupations: occupations,
    );
  }

  /// `/library/people/{key}/credits` — one group per role type.
  static List<PersonCreditGroup> parseCredits(Map<String, dynamic>? root) => [
    for (final group in flexibleMapList(_container(root)['CreditGroup']))
      PersonCreditGroup(
        label: stringOrEmpty(group['title']),
        type: stringOrEmpty(group['type']),
        credits: [
          for (final credit in flexibleMapList(group['Credit']))
            if (firstFlexibleMap(credit['Metadata']) case final Map<String, dynamic> m) _credit(m, role: credit['role']),
        ],
      ),
  ];

  /// `/library/people/{key}/person_known_for` — the character is in `parentTitle`.
  static List<PersonCredit> parseKnownFor(Map<String, dynamic>? root) => [
    for (final m in flexibleMapList(_container(root)['Metadata'])) _credit(m, role: m['parentTitle']),
  ];

  static String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
