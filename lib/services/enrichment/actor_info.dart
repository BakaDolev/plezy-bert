/// Positive Wikidata enrichment for a cast/crew member's actor page.
///
/// Every [ActorInfo] instance is a trusted, positive result — the
/// never-show-wrong-data core (spec §6a) means there is no `found` flag
/// here. When [selectActorCandidate] can't safely pick a candidate, the
/// enrichment service returns `null` instead of an [ActorInfo].
///
/// Hand-written `fromJson`/`toJson` (no codegen) so this can be stored as a
/// raw JSON payload in `ApiCache`.
class ActorInfo {
  final String? qid;
  final int? bornYear;
  final int? diedYear;
  final List<String> occupations;
  final String? bio;
  final String? enwikiTitle;

  const ActorInfo({this.qid, this.bornYear, this.diedYear, this.occupations = const [], this.bio, this.enwikiTitle});

  factory ActorInfo.fromJson(Map<String, dynamic> json) {
    return ActorInfo(
      qid: json['qid'] as String?,
      bornYear: json['bornYear'] as int?,
      diedYear: json['diedYear'] as int?,
      occupations: List<String>.from(json['occupations'] as List<dynamic>? ?? const []),
      bio: json['bio'] as String?,
      enwikiTitle: json['enwikiTitle'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    if (qid != null) 'qid': qid,
    if (bornYear != null) 'bornYear': bornYear,
    if (diedYear != null) 'diedYear': diedYear,
    if (occupations.isNotEmpty) 'occupations': occupations,
    if (bio != null) 'bio': bio,
    if (enwikiTitle != null) 'enwikiTitle': enwikiTitle,
  };
}
