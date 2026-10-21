/// Wikidata QIDs (P106 occupation values) that qualify a candidate as an
/// actor for enrichment purposes. Spec §6a.
const Set<String> kActingOccupations = {
  'Q33999', // actor
  'Q10800557', // film actor
  'Q10798782', // television actor
  'Q2405480', // voice actor
  'Q2259451', // stage actor
};

/// Word-boundary match for the cheap secondary "looks like an actor"
/// signal in a candidate's description (spec §6a). Boundary-anchored so
/// substrings like "factory"/"factor" don't false-positive on `actor`;
/// "voice actor" already satisfies this via the `actor` alternative, so it
/// isn't listed separately.
final RegExp _actingDescriptionPattern = RegExp(r'\b(actor|actress)\b', caseSensitive: false);

/// A candidate Wikidata entity for a cast/crew name, already reduced to the
/// fields [selectActorCandidate] needs. Built from the raw Wikidata
/// search+entity JSON by `ActorEnrichmentClient`.
class WikidataCandidate {
  final String qid;
  final bool isHuman;
  final Set<String> occupationQids;
  final bool hasEnwikiSitelink;
  final String description;

  /// The entity's display label (locale-preferred, English fallback).
  final String label;

  /// Every other label/alias Wikidata returned for the entity, across the
  /// requested languages — the exact-name gate accepts a match against any
  /// of these too (spec §6a controller addendum).
  final List<String> aliases;

  const WikidataCandidate({
    required this.qid,
    required this.isHuman,
    required this.occupationQids,
    required this.hasEnwikiSitelink,
    required this.description,
    required this.label,
    this.aliases = const [],
  });
}

/// Picks the one Wikidata candidate safe to enrich [name] with, or `null`
/// when zero or more than one candidate qualifies.
///
/// The never-show-wrong-data core (spec §6a): a candidate must be human
/// (P31=Q5), hold an acting occupation, carry an English Wikipedia
/// sitelink, describe itself with an acting term, AND have its `label` or
/// one of its `aliases` match [name] **exactly** (case-insensitive,
/// whitespace-trimmed). That last gate closes a real seam: Wikidata's
/// `wbsearchentities` matches labels and aliases fuzzily/by-prefix, so a
/// single non-exact survivor could still be the wrong person. Ambiguity
/// (zero or 2+ qualifying candidates) is treated the same as no match —
/// silence over a guess.
String? selectActorCandidate({required String name, required List<WikidataCandidate> candidates}) {
  final normalizedName = _normalizeForMatch(name);
  final accepted = candidates
      .where((candidate) => _isAcceptableCandidate(candidate, normalizedName))
      .toList(growable: false);
  return accepted.length == 1 ? accepted.single.qid : null;
}

bool _isAcceptableCandidate(WikidataCandidate candidate, String normalizedName) {
  if (!candidate.isHuman) return false;
  if (candidate.occupationQids.intersection(kActingOccupations).isEmpty) return false;
  if (!candidate.hasEnwikiSitelink) return false;
  if (!_actingDescriptionPattern.hasMatch(candidate.description)) return false;
  return _hasExactNameMatch(candidate, normalizedName);
}

bool _hasExactNameMatch(WikidataCandidate candidate, String normalizedName) {
  if (_normalizeForMatch(candidate.label) == normalizedName) return true;
  return candidate.aliases.any((alias) => _normalizeForMatch(alias) == normalizedName);
}

String _normalizeForMatch(String value) => value.trim().toLowerCase();
