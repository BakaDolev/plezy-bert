import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import '../trackers/tracker_http_client.dart';
import 'actor_info.dart';
import 'actor_matcher.dart';

/// Keyless Wikidata + Wikipedia enrichment for the actor detail page
/// (spec §4, §6a, §8): `wbsearchentities` → `wbgetentities` →
/// [selectActorCandidate] → the Wikipedia REST summary.
///
/// Fails closed everywhere: any HTTP error, timeout, thrown exception,
/// malformed body, or ambiguous/no match returns `null` — this never throws
/// to the caller, which is what lets the actor page treat enrichment as a
/// purely decorative, best-effort slot (spec §4/§9).
class ActorEnrichmentClient {
  /// Wikimedia requires a descriptive User-Agent with contact info for
  /// unauthenticated API traffic; the bare `'Plezy'` UA used elsewhere
  /// (`media_image_helper.dart:314`) is non-compliant. Self-contained (not
  /// derived from `fork_info.dart`, which doesn't exist on this branch) so
  /// this stays rebase-clean against the upstream `edde746/plezy` PR.
  static const String userAgent = 'Plezy/2.16.0 (+https://github.com/edde746/plezy; actor enrichment)';

  static const Map<String, String> _headers = {'User-Agent': userAgent, 'Accept': 'application/json'};

  static const String _wikidataApiBase = 'https://www.wikidata.org/w/api.php';
  static const String _defaultLocale = 'en';
  static const int _searchLimit = 7;

  final TrackerHttpClient _http;

  ActorEnrichmentClient({http.Client? httpClient})
    : _http = TrackerHttpClient(logLabel: 'ActorEnrichment', httpClient: httpClient);

  void dispose() => _http.dispose();

  /// Resolves [name] to a positive [ActorInfo], or `null` on any failure or
  /// when no single confident match exists (see [selectActorCandidate]).
  /// [localeCode] drives both the Wikidata search language and the
  /// Wikipedia summary's host locale; it defaults to English.
  Future<ActorInfo?> fetch({required String name, String? localeCode}) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return null;
    final locale = (localeCode == null || localeCode.trim().isEmpty) ? _defaultLocale : localeCode.trim();

    try {
      final hits = await _search(name: trimmedName, locale: locale);
      if (hits.isEmpty) return null;

      final candidateQids = hits.keys.toList(growable: false);
      final entities = await _getEntities(candidateQids: candidateQids, locale: locale);
      if (entities.isEmpty) return null;

      final candidates = <WikidataCandidate>[
        for (final qid in candidateQids)
          if (entities[qid] is Map)
            _toCandidate(qid: qid, entity: entities[qid] as Map, hit: hits[qid]!, locale: locale),
      ];
      if (candidates.isEmpty) return null;

      final selectedQid = selectActorCandidate(name: trimmedName, candidates: candidates);
      if (selectedQid == null) return null;

      final selectedEntity = entities[selectedQid];
      if (selectedEntity is! Map) return null;

      return await _buildActorInfo(qid: selectedQid, entity: selectedEntity, entities: entities, locale: locale);
    } catch (e, stackTrace) {
      appLogger.d('ActorEnrichment: fetch failed for "$trimmedName" (non-fatal)', error: e, stackTrace: stackTrace);
      return null;
    }
  }

  /// `wbsearchentities`: candidate QIDs keyed by their search-result label,
  /// description and (matched) aliases. The search-result description is
  /// LOCALIZED to `locale` (spec §6a's "search result's short description")
  /// and is only used as a fallback for the acting-term gate input — see
  /// [_englishDescriptionFor] / [_toCandidate], which prefer the entity's
  /// ENGLISH description from `wbgetentities` since the gate's regex is
  /// English-only.
  Future<Map<String, _SearchHit>> _search({required String name, required String locale}) async {
    final uri = Uri.parse(_wikidataApiBase).replace(
      queryParameters: {
        'action': 'wbsearchentities',
        'search': name,
        'language': locale,
        'uselang': locale,
        'type': 'item',
        'format': 'json',
        'limit': '$_searchLimit',
      },
    );
    final res = await _http.send('GET', uri, headers: _headers, operation: 'ActorEnrichment search');
    if (res.statusCode != 200) return const {};

    final decoded = TrackerHttpClient.decodeJson(res.body);
    if (decoded is! Map) return const {};
    final results = decoded['search'];
    if (results is! List) return const {};

    final hits = <String, _SearchHit>{};
    for (final result in results) {
      if (result is! Map) continue;
      final id = result['id'];
      if (id is! String) continue;
      final label = result['label'];
      final description = result['description'];
      hits[id] = _SearchHit(
        label: label is String ? label : '',
        description: description is String ? description : '',
        aliases: _flattenAliasField(result['aliases']),
      );
    }
    return hits;
  }

  /// `wbgetentities` for [candidateQids] plus every [kActingOccupations]
  /// QID batched into the same request — one extra call's worth of ids,
  /// not an extra round trip — so the ACTING-subset occupation labels used
  /// as [_resolveOccupations]'s fail-soft fallback are already in hand once
  /// a candidate is selected, localized the same way as the candidate
  /// labels. The winner's FULL P106 set (spec: Plex-style "Actor ·
  /// Producer") is resolved separately once the winner is known — see
  /// [_resolveOccupations] / [_getOccupationLabels].
  Future<Map<String, dynamic>> _getEntities({required List<String> candidateQids, required String locale}) async {
    final ids = {...candidateQids, ...kActingOccupations}.toList(growable: false);
    final uri = Uri.parse(_wikidataApiBase).replace(
      queryParameters: {
        'action': 'wbgetentities',
        'ids': ids.join('|'),
        'props': 'labels|aliases|claims|sitelinks|descriptions',
        'languages': _languagesParam(locale),
        'format': 'json',
      },
    );
    final res = await _http.send('GET', uri, headers: _headers, operation: 'ActorEnrichment entities');
    if (res.statusCode != 200) return const {};

    final decoded = TrackerHttpClient.decodeJson(res.body);
    if (decoded is! Map) return const {};
    final entities = decoded['entities'];
    if (entities is! Map) return const {};
    return Map<String, dynamic>.from(entities);
  }

  String _languagesParam(String locale) => locale == _defaultLocale ? _defaultLocale : '$locale|$_defaultLocale';

  WikidataCandidate _toCandidate({
    required String qid,
    required Map entity,
    required _SearchHit hit,
    required String locale,
  }) {
    final claims = entity['claims'];
    final claimsMap = claims is Map ? claims : const {};

    // Union of every label/alias Wikidata returned across the requested
    // languages, plus what the search step itself matched on — this feeds
    // the exact-name gate in selectActorCandidate (controller addendum).
    final nameForms = <String>{};
    final entityLabel = _labelFor(entity, locale);
    if (entityLabel != null) nameForms.add(entityLabel);
    if (hit.label.isNotEmpty) nameForms.add(hit.label);
    _collectLanguageValues(entity['labels'], nameForms);
    _collectLanguageValues(entity['aliases'], nameForms);
    nameForms.addAll(hit.aliases);

    return WikidataCandidate(
      qid: qid,
      isHuman: _hasClaimValueId(claimsMap, 'P31', 'Q5'),
      occupationQids: _occupationQids(claimsMap),
      hasEnwikiSitelink: _enwikiTitle(entity) != null,
      // The matcher's acting-description gate is an English-only regex
      // (`actor_matcher.dart`'s `_actingDescriptionPattern`), so it must see
      // the ENGLISH description — `wbsearchentities`' `hit.description` is
      // localized to `locale` and would silently fail the gate for every
      // non-English UI (e.g. French "acteur américain"). Falls back to the
      // localized search description only when Wikidata has no English
      // description at all — still better than an empty gate input.
      description: _englishDescriptionFor(entity) ?? hit.description,
      label: entityLabel ?? (hit.label.isNotEmpty ? hit.label : qid),
      aliases: nameForms.toList(growable: false),
    );
  }

  /// The entity's ENGLISH `description` (`descriptions.en.value`), or
  /// `null` if Wikidata has none — deliberately English-only (no
  /// locale-preferred fallback like [_labelFor]) since this only feeds the
  /// matcher's English-only acting-term gate, never anything user-visible.
  String? _englishDescriptionFor(Map entity) {
    final descriptions = entity['descriptions'];
    if (descriptions is! Map) return null;
    final english = descriptions[_defaultLocale];
    if (english is! Map) return null;
    final value = english['value'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<ActorInfo> _buildActorInfo({
    required String qid,
    required Map entity,
    required Map<String, dynamic> entities,
    required String locale,
  }) async {
    final claims = entity['claims'];
    final claimsMap = claims is Map ? claims : const {};

    final bornYear = _yearFromTimeClaim(claimsMap, 'P569');
    final diedYear = _yearFromTimeClaim(claimsMap, 'P570');
    final occupationQids = _occupationQids(claimsMap);

    final occupations = await _resolveOccupations(occupationQids: occupationQids, entities: entities, locale: locale);

    final enwikiTitle = _enwikiTitle(entity);
    final bio = enwikiTitle == null ? null : await _fetchSummary(title: enwikiTitle);

    return ActorInfo(
      qid: qid,
      bornYear: bornYear,
      diedYear: diedYear,
      occupations: occupations,
      bio: bio,
      enwikiTitle: enwikiTitle,
    );
  }

  /// The winner's REAL occupations line (spec: Plex-style "Actor ·
  /// Producer"), not just the acting-gate subset — resolved from the
  /// winner's full P106 QID set (already in hand from [_occupationQids] on
  /// the already-fetched winner entity, per the matching step; no re-fetch
  /// of the entity itself). Localized labels for that full set need one
  /// extra `wbgetentities` call ([_getOccupationLabels]) since only the
  /// [kActingOccupations] subset rode along with the batched entities call.
  /// Fails soft to the acting-only labels already in hand on ANY error from
  /// that extra call — a label-fetch hiccup must never null the whole
  /// enrichment result over the occupations line.
  Future<List<String>> _resolveOccupations({
    required Set<String> occupationQids,
    required Map<String, dynamic> entities,
    required String locale,
  }) async {
    final actingOnly = _actingOccupationLabels(occupationQids: occupationQids, entities: entities, locale: locale);
    if (occupationQids.isEmpty) return actingOnly;

    try {
      final occupationEntities = await _getOccupationLabels(occupationQids: occupationQids, locale: locale);
      if (occupationEntities.isEmpty) return actingOnly;

      final full = <String>[];
      for (final occupationQid in occupationQids) {
        final label = _labelFor(occupationEntities[occupationQid], locale);
        if (label != null) full.add(label);
      }
      return full.isEmpty ? actingOnly : full;
    } catch (e, stackTrace) {
      appLogger.d(
        'ActorEnrichment: occupation label fetch failed (non-fatal, falling back)',
        error: e,
        stackTrace: stackTrace,
      );
      return actingOnly;
    }
  }

  /// Acting-subset occupation labels already available from the batched
  /// [_getEntities] response — the fail-soft fallback [_resolveOccupations]
  /// returns when the full-P106 label call errors.
  List<String> _actingOccupationLabels({
    required Set<String> occupationQids,
    required Map<String, dynamic> entities,
    required String locale,
  }) {
    final occupations = <String>[];
    for (final occupationQid in kActingOccupations) {
      if (!occupationQids.contains(occupationQid)) continue;
      final label = _labelFor(entities[occupationQid], locale);
      if (label != null) occupations.add(label);
    }
    return occupations;
  }

  /// `wbgetentities` for the winner's FULL P106 set, labels only — same
  /// locale-with-English-fallback localization as [_getEntities], just a
  /// separate call because this set (all occupations, not only the acting
  /// ones) is only known once the winner is selected.
  Future<Map<String, dynamic>> _getOccupationLabels({
    required Set<String> occupationQids,
    required String locale,
  }) async {
    final uri = Uri.parse(_wikidataApiBase).replace(
      queryParameters: {
        'action': 'wbgetentities',
        'ids': occupationQids.join('|'),
        'props': 'labels',
        'languages': _languagesParam(locale),
        'format': 'json',
      },
    );
    final res = await _http.send('GET', uri, headers: _headers, operation: 'ActorEnrichment occupations');
    if (res.statusCode != 200) return const {};

    final decoded = TrackerHttpClient.decodeJson(res.body);
    if (decoded is! Map) return const {};
    final entities = decoded['entities'];
    if (entities is! Map) return const {};
    return Map<String, dynamic>.from(entities);
  }

  /// Wikipedia REST summary always comes from `en.wikipedia.org`, paired
  /// with [title] (the English `sitelinks.enwiki` title) — the ONLY host
  /// that title reliably resolves against (spec fix: the app-locale host
  /// 404s for a non-English `localeCode` since the title itself stays
  /// English). Bio stays English; true localization is out of scope.
  Future<String?> _fetchSummary({required String title}) async {
    final uri = Uri.https('en.wikipedia.org', '/api/rest_v1/page/summary/${title.replaceAll(' ', '_')}');
    final res = await _http.send('GET', uri, headers: _headers, operation: 'ActorEnrichment summary');
    if (res.statusCode != 200) return null;

    final decoded = TrackerHttpClient.decodeJson(res.body);
    if (decoded is! Map) return null;
    final extract = decoded['extract'];
    return extract is String && extract.isNotEmpty ? extract : null;
  }

  // --- Defensive claim/label parsing ---

  bool _hasClaimValueId(Map claims, String property, String targetId) {
    final statements = claims[property];
    if (statements is! List) return false;
    for (final statement in statements) {
      if (_snakValueId(statement) == targetId) return true;
    }
    return false;
  }

  Set<String> _occupationQids(Map claims) {
    final statements = claims['P106'];
    if (statements is! List) return const {};
    final ids = <String>{};
    for (final statement in statements) {
      final id = _snakValueId(statement);
      if (id != null) ids.add(id);
    }
    return ids;
  }

  /// The `P31`/`P106` snak's `datavalue.value.id` — a Wikidata item
  /// reference — or `null` for anything else (novalue/somevalue snaks,
  /// non-item datatypes, or a malformed statement).
  String? _snakValueId(Object? statement) {
    if (statement is! Map) return null;
    final mainsnak = statement['mainsnak'];
    if (mainsnak is! Map || mainsnak['snaktype'] != 'value') return null;
    final datavalue = mainsnak['datavalue'];
    if (datavalue is! Map) return null;
    final value = datavalue['value'];
    if (value is! Map) return null;
    final id = value['id'];
    return id is String ? id : null;
  }

  /// The first `P569`/`P570` statement's year, or `null` if the property is
  /// absent (spec: no `P570` ⇒ alive ⇒ `diedYear == null`, never a
  /// placeholder).
  int? _yearFromTimeClaim(Map claims, String property) {
    final statements = claims[property];
    if (statements is! List || statements.isEmpty) return null;
    final first = statements.first;
    if (first is! Map) return null;
    final mainsnak = first['mainsnak'];
    if (mainsnak is! Map || mainsnak['snaktype'] != 'value') return null;
    final datavalue = mainsnak['datavalue'];
    if (datavalue is! Map) return null;
    final value = datavalue['value'];
    if (value is! Map) return null;
    final time = value['time'];
    if (time is! String) return null;
    return _parseYear(time);
  }

  /// Wikidata time values look like `+1952-07-09T00:00:00Z` — a leading
  /// sign is always present, including for BCE dates.
  int? _parseYear(String wikidataTime) {
    final match = RegExp(r'^([+-]\d+)-\d\d-\d\d').firstMatch(wikidataTime);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  String? _enwikiTitle(Map entity) {
    final sitelinks = entity['sitelinks'];
    if (sitelinks is! Map) return null;
    final enwiki = sitelinks['enwiki'];
    if (enwiki is! Map) return null;
    final title = enwiki['title'];
    return title is String && title.isNotEmpty ? title : null;
  }

  /// Preferred label for an entity map: [locale] first, English fallback —
  /// spec §8's "app-locale labels ... with English fallback".
  String? _labelFor(Object? entity, String locale) {
    if (entity is! Map) return null;
    final labels = entity['labels'];
    if (labels is! Map) return null;
    final localized = labels[locale];
    if (localized is Map && localized['value'] is String) return localized['value'] as String;
    if (locale == _defaultLocale) return null;
    final english = labels[_defaultLocale];
    if (english is Map && english['value'] is String) return english['value'] as String;
    return null;
  }

  /// Flattens a Wikidata per-language map into [out] — handles both the
  /// `labels` shape (`{lang: {value}}`) and the `aliases` shape
  /// (`{lang: [{value}, ...]}`).
  void _collectLanguageValues(Object? languageMap, Set<String> out) {
    if (languageMap is! Map) return;
    for (final entry in languageMap.values) {
      if (entry is Map && entry['value'] is String) {
        out.add(entry['value'] as String);
      } else if (entry is List) {
        for (final item in entry) {
          if (item is Map && item['value'] is String) out.add(item['value'] as String);
        }
      }
    }
  }

  /// `wbsearchentities` returns a flat `List<String>` of matched aliases;
  /// defensively also accepts `{value}` maps in case that ever changes.
  List<String> _flattenAliasField(Object? aliases) {
    if (aliases is! List) return const [];
    final out = <String>[];
    for (final item in aliases) {
      if (item is String) {
        out.add(item);
      } else if (item is Map && item['value'] is String) {
        out.add(item['value'] as String);
      }
    }
    return out;
  }
}

class _SearchHit {
  final String label;
  final String description;
  final List<String> aliases;

  const _SearchHit({required this.label, required this.description, required this.aliases});
}
