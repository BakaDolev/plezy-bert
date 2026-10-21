import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../api_cache.dart';
import 'actor_enrichment_client.dart';
import 'actor_info.dart';

/// `ApiCache`-backed coordinator for the Plex actor-page enrichment lookup
/// (spec §4/§7).
///
/// Cache-first with a TTL split between confirmed misses and positive hits:
/// a `{found: false}` row (no confident Wikidata match) is treated as a
/// known-negative and short-circuits without ever touching the network,
/// while a positive row survives far longer since an actor's bio/birth year
/// rarely changes. Offline callers get whatever row exists, however stale,
/// and never reach the client.
class ActorEnrichmentService {
  /// How long a negative (`{found: false}`) row is served without a retry.
  /// Short enough that a temporarily-unmatched actor (a Wikidata edit, a new
  /// sitelink) gets re-checked reasonably soon.
  static const Duration negativeTtl = Duration(days: 7);

  /// How long a positive row is served before refetching. Long because the
  /// underlying facts (birth year, occupations, bio) are effectively static.
  static const Duration positiveTtl = Duration(days: 90);

  final ApiCache _cache;
  final ActorEnrichmentClient _client;

  ActorEnrichmentService(this._cache, this._client);

  String _endpoint(String personId) => '/enrichment/person/$personId';

  /// Resolves [name] (a Plex cast/crew member, `personId` identifying their
  /// row within [serverId]'s cache namespace) to enrichment info, going
  /// through the cache before ever touching the network.
  ///
  /// Fails soft throughout: a cache read/write error is logged and treated
  /// as a miss/no-op rather than thrown, and a client exception (which
  /// shouldn't happen — [ActorEnrichmentClient.fetch] already fails closed)
  /// is guarded the same way.
  Future<ActorInfo?> enrichPlex({
    required String serverId,
    required String personId,
    required String name,
    String? localeCode,
    bool online = true,
  }) async {
    final id = ServerId(serverId);
    final endpoint = _endpoint(personId);

    if (!online) {
      final row = await _tryGet(id, endpoint);
      return _parse(row);
    }

    // First read: anything written within the negative TTL is fresh,
    // whether positive or negative — this is the common case.
    final recentRow = await _tryGetIfFresh(id, endpoint, negativeTtl);
    if (recentRow != null) return _parse(recentRow);

    // Second read: a positive row survives up to the longer TTL. A negative
    // row that only clears this wider window is a stale negative — fall
    // through and treat it as a miss.
    final olderRow = await _tryGetIfFresh(id, endpoint, positiveTtl);
    if (olderRow != null && olderRow['found'] == true) {
      return ActorInfo.fromJson(olderRow);
    }

    ActorInfo? info;
    try {
      info = await _client.fetch(name: name, localeCode: localeCode);
    } catch (e, stackTrace) {
      // ActorEnrichmentClient.fetch already fails closed and shouldn't
      // throw; guarded anyway so a coordinator bug can't propagate out.
      appLogger.d('ActorEnrichmentService: client fetch threw (non-fatal)', error: e, stackTrace: stackTrace);
      info = null;
    }

    final payload = info == null ? const {'found': false} : {...info.toJson(), 'found': true};
    await _tryPut(id, endpoint, payload);

    return info;
  }

  /// Maps a Jellyfin **Person** item's own server metadata straight to
  /// [ActorInfo] — a pure, network-free mapping (no client, no cache).
  /// Unlike [enrichPlex], Jellyfin's server is the source of truth for a
  /// person's bio/dates (`Overview`/`PremiereDate`, already mapped onto
  /// [MediaItem.summary]/[MediaItem.originallyAvailableAt] by
  /// `jellyfin_mappers.dart`), so there is no Wikidata lookup and nothing to
  /// cache here — the caller fetches [person] via its own `fetchItem` call
  /// and passes the result straight in.
  ///
  /// [ActorInfo.diedYear] is always `null`: [MediaItem] carries no `EndDate`
  /// field, and Jellyfin is the non-primary backend for this feature, so
  /// recovering it via a raw (unmapped) fetch is deferred past v1.
  ///
  /// Returns `null` when [person] is absent, or when neither a bio nor a
  /// born year could be extracted — nothing worth showing.
  Future<ActorInfo?> enrichJellyfin({required MediaItem? person}) async {
    if (person == null) return null;

    final summary = person.summary;
    final bio = summary != null && summary.isNotEmpty ? summary : null;
    final bornYear = _leadingYear(person.originallyAvailableAt);

    if (bio == null && bornYear == null) return null;

    return ActorInfo(bornYear: bornYear, bio: bio);
  }

  /// Parses the leading 4-digit year out of a `YYYY-MM-DD`/ISO-ish date
  /// string. Returns `null` for absent, empty, or unparseable input.
  static int? _leadingYear(String? date) {
    if (date == null || date.isEmpty) return null;
    final match = RegExp(r'^(\d{4})').firstMatch(date);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  ActorInfo? _parse(Map<String, dynamic>? row) {
    if (row == null || row['found'] == false) return null;
    return ActorInfo.fromJson(row);
  }

  Future<Map<String, dynamic>?> _tryGet(ServerId serverId, String endpoint) async {
    try {
      return await _cache.get(serverId, endpoint);
    } catch (e, stackTrace) {
      appLogger.d('ActorEnrichmentService: cache read failed (non-fatal)', error: e, stackTrace: stackTrace);
      return null;
    }
  }

  Future<Map<String, dynamic>?> _tryGetIfFresh(ServerId serverId, String endpoint, Duration maxAge) async {
    try {
      return await _cache.getIfFresh(serverId, endpoint, maxAge: maxAge);
    } catch (e, stackTrace) {
      appLogger.d('ActorEnrichmentService: cache read failed (non-fatal)', error: e, stackTrace: stackTrace);
      return null;
    }
  }

  Future<void> _tryPut(ServerId serverId, String endpoint, Map<String, dynamic> data) async {
    try {
      await _cache.put(serverId, endpoint, data);
    } catch (e, stackTrace) {
      appLogger.d('ActorEnrichmentService: cache write failed (non-fatal)', error: e, stackTrace: stackTrace);
    }
  }
}
