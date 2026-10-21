import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../connection/connection_registry.dart';
import '../media/ids.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/library_query.dart';
import '../media/media_server_client.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile_connection_registry.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/offline_mode_provider.dart';
import '../services/api_cache.dart';
import '../services/enrichment/actor_enrichment_client.dart';
import '../services/enrichment/actor_enrichment_service.dart';
import '../services/enrichment/actor_info.dart';
import '../services/enrichment/person_online_page.dart';
import '../services/plex_discover_client.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/error_message_utils.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../focus/key_event_utils.dart';
import '../widgets/actor_hero_header.dart';
import '../widgets/clickable_detail_text.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/optimized_media_image.dart' show blurArtwork;
import '../widgets/overlay_sheet.dart';
import '../widgets/person_credit_card.dart';
import '../widgets/person_credit_strip.dart';
import '../widgets/person_filmography_list.dart';
import '../widgets/system_bottom_inset.dart';
import '../i18n/strings.g.dart';
import 'actor_character_resolver.dart';
import 'actor_filmography.dart';
import 'base_media_list_detail_screen.dart';
import 'focusable_detail_screen_mixin.dart';
import '../mixins/grid_focus_node_mixin.dart';
import '../focus/focusable_action_bar.dart';
import 'libraries/content_state_builder.dart';

/// Screen for a cast/crew member: a Plex-style page with a profile header, the
/// titles in your library, a "Known For" row, and the full tabbed filmography.
///
/// The library grid comes from the local server (`fetchPersonMedia`); the
/// "Known For" row, the full filmography, and the richer profile all come from
/// Plex's online Discover provider ([PlexDiscoverClient.fetchPersonPage], keyed
/// by [personTagKey]). The online sections are best-effort: offline, no key, or
/// the enrichment toggle off leaves a clean library-only page.
class ActorMediaScreen extends StatefulWidget {
  final String actorName;
  final String personId;

  /// Plex's global person key ([MediaRole.tagKey]) — the bridge to the online
  /// Discover person page. Null on backends/rows that don't expose it, which
  /// simply skips the online sections.
  final String? personTagKey;
  final String? actorThumb;
  final String? characterName;
  final String serverId;
  final String? serverName;
  final MediaBackend backend;

  const ActorMediaScreen({
    super.key,
    required this.actorName,
    required this.personId,
    this.personTagKey,
    this.actorThumb,
    this.characterName,
    required this.serverId,
    this.serverName,
    required this.backend,
  });

  /// Test seam: when set, used instead of constructing a real
  /// [ActorEnrichmentClient] + [ActorEnrichmentService]. Lets tests exercise
  /// the backend-routing/gating logic against a canned service with no network
  /// traffic. Tests must reset this to `null` in `tearDown` — it is a static.
  @visibleForTesting
  static ActorEnrichmentService Function(ApiCache cache)? debugEnrichmentServiceFactory;

  @override
  State<ActorMediaScreen> createState() => _ActorMediaScreenState();
}

class _ActorMediaScreenState extends BaseMediaListDetailScreen<ActorMediaScreen>
    with
        GridFocusNodeMixin<ActorMediaScreen>,
        FocusableDetailScreenMixin<ActorMediaScreen>,
        TickerProviderStateMixin<ActorMediaScreen> {
  static const int _personMediaPageSize = 200;

  /// Space kept below the last TV section so its bottom row stays clear of the
  /// screen edge, which many TVs crop (Android TV's overscan-safe margin is
  /// 27dp top and bottom on its 960x540dp screen).
  static const double _tvBottomSafeMargin = 27;

  /// The person's online Discover page (bio, "Known For", full filmography).
  /// Null until (and unless) the lookup lands with content.
  PersonOnlinePage? _onlinePage;

  /// Drives the filmography tab bar (over [_filmoGroups]) when there are ≥2
  /// non-empty credit groups; null otherwise (a single group renders bare).
  TabController? _tabController;

  /// The filmography credit-group index currently rendered, mirrored from
  /// [_tabController] so a tab tap swaps the list below inside one scroll view.
  int _shownTabIndex = 0;

  /// Header enrichment (bio/occupation/born). A [ValueNotifier] rather than
  /// [setState] so a [ValueListenableBuilder] scopes rebuilds to the header
  /// alone. Fed from the Plex profile when available, else Wikidata; stays at
  /// this idle default when the setting is off or the lookup finds nothing.
  final ValueNotifier<({bool loading, ActorInfo? info})> _enrichment = ValueNotifier((loading: false, info: null));

  /// Owns the Wikidata/Wikipedia HTTP client backing the fallback enrichment.
  ActorEnrichmentClient? _enrichmentClient;

  /// TV D-pad focus for the fixed-hero + content layout (S16-actor-dpad). The
  /// hero stays pinned (never scrolls away), and the remote walks
  /// hero "Read more" → In your library grid → Known For strip → Full
  /// filmography tile. Unused on pointer platforms (the hero is a normal sliver
  /// and cards are tapped).
  final FocusNode _bioFocusNode = FocusNode(debugLabel: 'actor_bio'); // hero "Read more"

  /// Stable GlobalKeys for the TV content blocks so the focus chain can hand
  /// focus between them: the Known For rail ([PersonCreditStrip]) and the
  /// filmography list ([PersonFilmographyList]).
  final GlobalKey<PersonCreditStripState> _knownForStripKey = GlobalKey<PersonCreditStripState>();
  final GlobalKey<PersonFilmographyListState> _filmoListKey = GlobalKey<PersonFilmographyListState>();

  /// One-shot guard so the TV opening focus is applied once, after the library
  /// items and enrichment have both had a chance to land.
  bool _tvInitialFocusApplied = false;

  @override
  void initState() {
    super.initState();
    // TV: when focus reaches the top-left library item, snap the page fully to
    // the top so the "In your library" heading (a sliver above the grid) is
    // revealed — the grid item's own scroll-into-view stops at the item and
    // leaves the heading just off-screen. The actor-page twin of the episode
    // page's return-to-top fix (S16-tv-episode-scroll).
    firstItemFocusNode.addListener(_scrollGridTopIntoViewOnTv);
    unawaited(_startEnrichment());
  }

  void _scrollGridTopIntoViewOnTv() {
    if (!mounted || !PlatformDetector.isTV() || !firstItemFocusNode.hasFocus) return;
    // The focused grid card centres itself (FocusableWrapper, scrollAlignment
    // 0.5) in a post-frame callback, which scrolls the "In your library" heading
    // off the top. Our listener fires first (added before the card's Focus), so
    // snap to offset 0 on the frame AFTER the card's centering — making ours the
    // last scroll, leaving the page at the top with the heading shown
    // (S18-actor-grid-scroll). Double post-frame = one frame past the card's.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !firstItemFocusNode.hasFocus || !scrollController.hasClients) return;
        unawaited(scrollController.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
      });
    });
  }

  @override
  MediaItem get mediaItem => MediaItem(
    id: '',
    backend: widget.backend,
    kind: MediaKind.unknown,
    serverId: widget.serverId,
    serverName: widget.serverName,
  );

  @override
  String get title => widget.actorName;

  @override
  String get emptyMessage => t.discover.noContentAvailable;

  @override
  bool get hasItems => items.isNotEmpty || (_onlinePage?.hasContent ?? false);

  @override
  void dispose() {
    _enrichment.dispose();
    _enrichmentClient?.dispose();
    _tabController?.dispose();
    _bioFocusNode.dispose();
    firstItemFocusNode.removeListener(_scrollGridTopIntoViewOnTv);
    disposeFocusResources();
    super.dispose();
  }

  // ── TV D-pad chain: fixed hero → grid → Known For rail → filmography list ─
  // The hero is pinned (never scrolls away), so open-at-top is structural.
  // Below it a scroll region holds the library grid, then the Known For rail
  // ([PersonCreditStrip]), then the whole filmography as a role-tabbed
  // [PersonFilmographyList]. Empty blocks are skipped so focus is never trapped.

  bool get _hasBio => _enrichment.value.info?.bio?.isNotEmpty ?? false;

  List<PersonCredit> get _knownForCredits => _onlinePage?.knownFor ?? const <PersonCredit>[];
  bool get _hasKnownFor => _knownForCredits.isNotEmpty;
  bool get _hasFilmo => _filmoGroups.isNotEmpty;

  /// The focusable content blocks below the hero, in vertical order — only the
  /// ones with content. Drives the Up/Down chain between sections.
  List<_TvBlock> get _tvBlocks => [
    if (items.isNotEmpty) _TvBlock.grid,
    if (_hasKnownFor) _TvBlock.knownFor,
    if (_hasFilmo) _TvBlock.filmo,
  ];

  void _focusBlock(_TvBlock block) {
    switch (block) {
      case _TvBlock.grid:
        navigateToGrid();
      case _TvBlock.knownFor:
        _knownForStripKey.currentState?.requestFocus();
      case _TvBlock.filmo:
        _filmoListKey.currentState?.requestFocus();
    }
  }

  /// Grid first-row UP → the hero "Read more" when a bio is shown; else no-op
  /// (the hero is pinned and always visible, so there's nothing to reveal).
  @override
  void navigateToAppBar() {
    if (PlatformDetector.isTV()) {
      if (_hasBio && _bioFocusNode.context != null) _bioFocusNode.requestFocus();
      return;
    }
    super.navigateToAppBar();
  }

  /// Hero "Read more" DOWN → the first content block below the hero.
  void _bioNavigateDown() {
    final blocks = _tvBlocks;
    if (blocks.isNotEmpty) _focusBlock(blocks.first);
  }

  /// Grid last-row DOWN → the block after the grid (Known For, else filmo).
  void _gridExitDown() => _blockDown(_TvBlock.grid);

  /// UP from [block] → the previous present block, else the hero "Read more".
  void _blockUp(_TvBlock block) {
    final blocks = _tvBlocks;
    final i = blocks.indexOf(block);
    if (i > 0) {
      _focusBlock(blocks[i - 1]);
    } else if (_hasBio && _bioFocusNode.context != null) {
      _bioFocusNode.requestFocus();
    }
  }

  /// DOWN from [block] → the next present block (no-op past the last).
  void _blockDown(_TvBlock block) {
    final blocks = _tvBlocks;
    final i = blocks.indexOf(block);
    if (i >= 0 && i + 1 < blocks.length) _focusBlock(blocks[i + 1]);
  }

  /// Opens the full bio in a scrollable popup — the TV counterpart of the
  /// phone's inline expand (a long bio can't be read via inline expand on a
  /// focus-driven 10-foot UI). The sheet's own FocusScope owns Back.
  void _openBioReadMore() {
    final bio = _enrichment.value.info?.bio;
    if (bio == null || bio.isEmpty) return;
    unawaited(
      OverlaySheetController.showAdaptive<void>(
        context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(widget.actorName, style: Theme.of(sheetContext).textTheme.titleLarge),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(bio, style: Theme.of(sheetContext).textTheme.bodyLarge?.copyWith(height: 1.5)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// TV opening focus: land on the first CONTENT section (library grid, else
  /// the first credit rail, else the hero "Read more"). The hero is pinned, so
  /// the actor info stays visible regardless — this fixes the "opens scrolled
  /// into the grid" bug without landing focus on the bio. Waits for enrichment
  /// to settle (so the rails exist) and is applied once.
  void _applyTvInitialFocus() {
    if (!PlatformDetector.isTV() || _tvInitialFocusApplied || !mounted) return;
    if (_enrichment.value.loading) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tvInitialFocusApplied) return;
      if (items.isNotEmpty) {
        firstItemFocusNode.requestFocus();
      } else if (_hasKnownFor && _knownForStripKey.currentState != null) {
        _knownForStripKey.currentState!.requestFocus();
      } else if (_hasFilmo && _filmoListKey.currentState != null) {
        _filmoListKey.currentState!.requestFocus();
      } else if (_hasBio && _bioFocusNode.context != null) {
        _bioFocusNode.requestFocus();
      } else {
        return; // nothing focusable yet; a later trigger will retry
      }
      _tvInitialFocusApplied = true;
    });
  }

  MediaServerClient get _mediaClient => context.getMediaClientForServer(ServerId(widget.serverId));

  /// The server may be offline (a cast tap from an offline detail): the header
  /// then shows the fallback avatar and the load reports the failure, instead
  /// of the lookup throwing during build.
  MediaServerClient? get _mediaClientOrNull => context.tryGetMediaClientForServer(ServerId(widget.serverId));

  /// The credit groups that actually have titles, in Plex's order.
  List<PersonCreditGroup> get _filmoGroups =>
      _onlinePage?.creditGroups.where((g) => g.credits.isNotEmpty).toList() ?? const [];

  /// Whether the app currently believes it's offline. Guarded: the actor
  /// screen's test harnesses don't always provide an [OfflineModeProvider], so
  /// an absent provider is treated as "online" rather than crashing.
  bool _readOffline() {
    try {
      return context.read<OfflineModeProvider>().isOffline;
    } on ProviderNotFoundException {
      return false;
    }
  }

  ActorEnrichmentService _enrichmentService() {
    final debugFactory = ActorMediaScreen.debugEnrichmentServiceFactory;
    final cache = _mediaClient.cache;
    if (debugFactory != null) return debugFactory(cache);
    _enrichmentClient ??= ActorEnrichmentClient();
    return ActorEnrichmentService(cache, _enrichmentClient!);
  }

  /// Fills the header and, for Plex, the online "Known For"/filmography
  /// sections. Fire-and-forget from [initState], gated on the
  /// `actorEnrichmentEnabled` setting.
  ///
  /// Plex prefers its own Discover person page (richer, and the only source for
  /// the online sections); it falls back to Wikidata when there is no person
  /// key, the lookup finds nothing, or we're offline. Jellyfin/Emby use the
  /// server's own Person metadata. Never throws: any failure degrades to the
  /// library-only page. Cancel-safe — every write is [mounted]-guarded.
  Future<void> _startEnrichment() async {
    final enabled = SettingsService.instanceOrNull?.read(SettingsService.actorEnrichmentEnabled) ?? true;
    if (!enabled) {
      // No enrichment → no bio; settle the TV opening focus on the grid/sections.
      _applyTvInitialFocus();
      return;
    }

    final offline = _readOffline();
    _enrichment.value = (loading: true, info: null);

    ActorInfo? info;
    try {
      if (widget.backend == MediaBackend.plex) {
        final page = offline ? null : await _fetchOnlinePersonPage();
        if (page != null && page.hasContent) {
          if (mounted) {
            setState(() => _onlinePage = page);
            _rebuildFilmographyTabs();
          }
          info = ActorInfo(bornYear: page.bornYear, occupations: page.occupations, bio: page.bio);
        } else {
          info = await _enrichmentService().enrichPlex(
            serverId: widget.serverId,
            personId: widget.personId,
            name: widget.actorName,
            localeCode: LocaleSettings.currentLocale.languageCode,
            online: !offline,
          );
        }
      } else {
        final person = await _mediaClient.fetchItem(widget.personId);
        if (!mounted) return;
        info = await _enrichmentService().enrichJellyfin(person: person);
      }
    } catch (e, stackTrace) {
      appLogger.d('ActorMediaScreen: enrichment failed (non-fatal)', error: e, stackTrace: stackTrace);
      info = null;
    }

    if (!mounted) return;
    _enrichment.value = (loading: false, info: info);
    // Enrichment settled — apply the TV opening focus (bio if present).
    _applyTvInitialFocus();
  }

  /// Fetches the Discover person page for [ActorMediaScreen.personTagKey].
  /// Returns null (never throws) when there is no key, no Discover session
  /// (e.g. no providers in a test tree), or the lookup fails.
  Future<PersonOnlinePage?> _fetchOnlinePersonPage() async {
    final tagKey = widget.personTagKey;
    if (tagKey == null || tagKey.isEmpty) return null;
    try {
      final session = await resolvePlexDiscoverSession(
        activeProfile: context.read<ActiveProfileProvider>(),
        connections: context.read<ConnectionRegistry>(),
        profileConnections: context.read<ProfileConnectionRegistry>(),
      );
      if (session == null) return null;
      final client = PlexDiscoverClient(session);
      try {
        return await client.fetchPersonPage(tagKey);
      } finally {
        client.dispose();
      }
    } catch (e, stackTrace) {
      appLogger.d('ActorMediaScreen: online person page lookup failed (non-fatal)', error: e, stackTrace: stackTrace);
      return null;
    }
  }

  /// Loads the actor's library titles (draining pagination). The grid paints
  /// immediately; per-title character captions fill in via [_hydratePlexCharacters].
  @override
  Future<void> loadItems() async {
    if (mounted) {
      setState(() {
        isLoading = true;
        errorMessage = null;
      });
    }

    try {
      final titles = await drainPages<MediaItem>(
        (start, size) => _mediaClient.fetchPersonMediaPage(widget.personId, start: start, size: size),
        pageSize: _personMediaPageSize,
      );
      if (!mounted) return;

      setState(() {
        items = titles;
        isLoading = false;
      });
      // TV walks the whole page top-to-bottom, so open at the top (bio/info)
      // rather than auto-jumping to the grid; [_applyTvInitialFocus] waits for
      // enrichment to settle. Pointer platforms keep the grid autofocus.
      if (PlatformDetector.isTV()) {
        _applyTvInitialFocus();
      } else {
        autoFocusFirstItemAfterLoad();
      }
      unawaited(_hydratePlexCharacters());
    } catch (error, stackTrace) {
      final message = localizedLoadErrorMessage(error, stackTrace, context: widget.actorName);
      if (!mounted) return;
      setState(() {
        errorMessage = message;
        isLoading = false;
      });
    }
  }

  @override
  List<FocusableAction> getAppBarActions() => [];

  /// Fills in the per-title character captions on the library grid after it has
  /// painted. Plex's per-person media list carries cast names but not the
  /// character played, so full metadata is re-fetched in one batched call
  /// ([PlexClient.fetchItemsByIds]) and folded back on ([mergeCastCrew]).
  /// Best-effort, non-blocking, Plex-only; a no-op offline or on Jellyfin.
  Future<void> _hydratePlexCharacters() async {
    if (widget.backend != MediaBackend.plex) return;
    final current = items;
    if (current.isEmpty || _readOffline()) return;
    final plex = context.tryGetPlexClientForServer(ServerId(widget.serverId));
    if (plex == null) return;

    final List<MediaItem> hydrated;
    try {
      final detailed = await plex.fetchItemsByIds([for (final title in current) title.id]);
      hydrated = mergeCastCrew(current, detailed);
    } catch (e, stackTrace) {
      appLogger.d('Actor page: Plex character hydration failed (non-fatal)', error: e, stackTrace: stackTrace);
      return;
    }
    if (!mounted) return;
    setState(() => items = hydrated);
  }

  /// (Re)builds [_tabController] for the filmography credit groups. A single
  /// group renders bare (no tab bar).
  void _rebuildFilmographyTabs() {
    _tabController?.dispose();
    _tabController = null;
    _shownTabIndex = 0;
    final groups = _filmoGroups;
    if (groups.length < 2) return;
    final controller = TabController(length: groups.length, vsync: this);
    controller.addListener(() {
      if (!mounted) return;
      if (controller.index != _shownTabIndex) {
        setState(() => _shownTabIndex = controller.index);
      }
    });
    _tabController = controller;
  }

  // ── Header ────────────────────────────────────────────────────────────────

  /// Hero sliver, scoped to [_enrichment] so the header updates without
  /// rebuilding the sections below. On TV the only focusable element is the
  /// bio's "Read more" target — the top of the D-pad chain — so the header is
  /// no longer wrapped in [ExcludeFocus]; everything else in it (portrait,
  /// facts, the Instagram link) carries no focus node and stays a non-target.
  /// The hero widget itself (portrait + facts + bio). Non-TV wraps it in a
  /// scroll sliver ([_buildActorHeader]); TV pins it above the scroll region.
  Widget _buildHeroContent() {
    final isTv = PlatformDetector.isTV();
    return ValueListenableBuilder<({bool loading, ActorInfo? info})>(
      valueListenable: _enrichment,
      builder: (context, state, _) {
        return ActorHeroHeader(
          actorName: widget.actorName,
          portraitPath: widget.actorThumb,
          characterName: widget.characterName,
          titleCount: items.length,
          enrichment: state.info,
          isEnrichmentLoading: state.loading,
          isTv: isTv,
          mediaClient: _mediaClientOrNull,
          // Richer profile facts from the Plex Discover page (null on the
          // Wikidata/offline paths, which keep the year-only born line).
          bornOn: _onlinePage?.bornAt,
          birthPlace: _onlinePage?.birthPlace,
          instagramUrl: _onlinePage?.instagramUrl,
          // TV: the bio is a "Read more" D-pad target that opens the full bio in
          // a scrollable popup; down → first content section. The hero is
          // pinned, so up has nothing to reveal.
          bioFocusNode: isTv ? _bioFocusNode : null,
          onBioReadMore: isTv ? _openBioReadMore : null,
          onBioNavigateDown: isTv ? _bioNavigateDown : null,
          onBioNavigateUp: null,
        );
      },
    );
  }

  Widget _buildActorHeader() => SliverToBoxAdapter(child: _buildHeroContent());

  /// TV hero on a poster "spotlight": the compact portrait + facts hero laid
  /// over a heavily-blurred band of the actor's OWN credit posters behind a
  /// scrim, so the actor page gets the cinematic feel of the show/episode pages
  /// (which use a real backdrop) — without the "stretched portrait wallpaper"
  /// look of the earlier attempt, since it's several posters, not the portrait
  /// (S17-actor-tv-style). Falls back to the plain hero when there are no
  /// posters to draw from.
  Widget _buildTvHero() {
    final hero = _buildHeroContent();
    final posters = _heroBackdropPosters();
    if (posters.isEmpty) return hero;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      children: [
        Positioned.fill(child: _posterSpotlightBackdrop(posters)),
        Positioned.fill(child: _heroSpotlightScrim(bg)),
        hero,
      ],
    );
  }

  /// A blurred band of the actor's credit posters tiled across the hero width —
  /// several posters (not the single portrait), so it reads as their body of
  /// work rather than one stretched photo.
  Widget _posterSpotlightBackdrop(List<String> posters) {
    final fallbackColor = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ClipRect(
      child: blurArtwork(
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final url in posters)
              Expanded(
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, _, _) => ColoredBox(color: fallbackColor),
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : ColoredBox(color: fallbackColor),
                ),
              ),
          ],
        ),
        sigma: 26,
        clip: false,
      ),
    );
  }

  /// Scrim over the poster backdrop: a left-heavy fade so the portrait and text
  /// stay legible, plus a bottom fade into the scaffold background so the hero
  /// melts into the content below — the same theme-aware posture as
  /// [TvSpotlightBackground] (the scrim is the scaffold colour, so it reads
  /// correctly in light and dark).
  Widget _heroSpotlightScrim(Color bg) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [bg.withValues(alpha: 0.95), bg.withValues(alpha: 0.72), bg.withValues(alpha: 0.42)],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.28), Colors.transparent, bg],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
      ),
    );
  }

  /// Up to six unique credit poster URLs (Known For first, then filmography) to
  /// paint the hero spotlight backdrop. Empty when the online page has none.
  List<String> _heroBackdropPosters() {
    final page = _onlinePage;
    if (page == null) return const [];
    final urls = <String>[];
    void addFrom(Iterable<PersonCredit> credits) {
      for (final c in credits) {
        if (urls.length >= 6) return;
        final u = c.posterUrl;
        if (u != null && u.isNotEmpty && !urls.contains(u)) urls.add(u);
      }
    }

    addFrom(page.knownFor);
    for (final g in page.creditGroups) {
      if (urls.length >= 6) break;
      addFrom(g.credits);
    }
    return urls;
  }

  // ── Sections ────────────────────────────────────────────────────────────

  Widget _sectionHeaderSliver(String title) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
    ),
  );

  /// The library grid: each title captioned with its year and the character the
  /// actor plays in it, stamped onto [MediaItem.parentTitle] so the media card
  /// renders it as the tile subtitle.
  Widget _buildLibraryGrid() {
    final onlineCharacters = _onlineCharactersByItemId();
    final captioned = [
      for (final item in items)
        if (_libraryCaption(item, onlineCharacters) case final caption?) item.copyWith(parentTitle: caption) else item,
    ];
    final isTv = PlatformDetector.isTV();
    return buildFocusableGrid(
      items: captioned,
      onRefresh: updateItem,
      // TV: last-row DOWN leaves the grid for Known For / Filmography.
      onExitDown: isTv ? _gridExitDown : null,
      // TV: the pinned hero leaves the grid about half the screen, so use the
      // compact cards (the Known For rail's size) — a full row, caption
      // included, then fits beneath it whatever the library density.
      densityOverride: isTv ? LibraryDensity.min : null,
    );
  }

  /// `"{year} · {character}"` for an acting credit, the year or character alone
  /// when only one is known, or null (no extra line) when neither is. The
  /// character comes from the local cast metadata, then falls back to the
  /// online filmography ([onlineCharacters]) — which names guest/one-off roles
  /// the local show/movie metadata frequently omits.
  String? _libraryCaption(MediaItem item, Map<String, String> onlineCharacters) {
    final year = item.year;
    final character = characterForItem(widget.actorName, item) ?? onlineCharacters[item.id];
    if (character != null && character.isNotEmpty) {
      return year != null ? '$year · $character' : character;
    }
    return year?.toString();
  }

  /// Character per library-item id, harvested from the online filmography.
  /// Plex's Discover credits reliably name characters that the local server's
  /// show/movie metadata often omits for a guest or minor role, so this
  /// backfills the "In your library" captions. Acting credits (whose `role` is
  /// the character) are preferred; `"Cast"` placeholders are skipped.
  Map<String, String> _onlineCharactersByItemId() {
    final page = _onlinePage;
    if (page == null || items.isEmpty) return const {};
    final result = <String, String>{};
    final groups = [
      ...page.creditGroups.where((g) => g.type == 'actor'),
      ...page.creditGroups.where((g) => g.type != 'actor'),
    ];
    for (final group in groups) {
      for (final credit in group.credits) {
        final character = credit.character;
        if (character == null || character.isEmpty || character.toLowerCase() == 'cast') continue;
        if (libraryMatchForCredit(credit, items) case final match?) {
          result.putIfAbsent(match.id, () => character);
        }
      }
    }
    return result;
  }

  /// "Known For" (pointer platforms) — a horizontal poster row. Each card opens
  /// the local library item when the title is in your library; non-owned online
  /// titles stay inert. (TV uses a focusable [PersonCreditStrip] instead.)
  Widget _buildKnownForRow(List<PersonCredit> credits) {
    return SizedBox(
      height: 258,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: credits.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final credit = credits[i];
          final libraryMatch = libraryMatchForCredit(credit, items);
          return PersonCreditCard(
            credit: credit,
            onTap: libraryMatch == null
                ? null
                : () => unawaited(navigateToMediaItemDetails(context, libraryMatch, onRefresh: updateItem)),
          );
        },
      ),
    );
  }

  /// Pinned tab bar over the filmography credit groups.
  Widget _buildFilmoTabBar(List<PersonCreditGroup> groups) {
    final theme = Theme.of(context);
    return SliverPersistentHeader(
      pinned: true,
      delegate: _TabBarHeaderDelegate(
        DecoratedBox(
          decoration: BoxDecoration(color: theme.scaffoldBackgroundColor),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [for (final g in groups) Tab(text: '${_capitalize(g.label)} (${g.credits.length})')],
          ),
        ),
      ),
    );
  }

  /// The selected credit group as a compact text list (Plex-style): a muted
  /// year column, the title, "· as {character}", and — for titles that are also
  /// in your library — an accented "On {server}" tag; those rows are tappable
  /// and open the local item.
  Widget _buildFilmoList(List<PersonCreditGroup> groups) {
    final index = _shownTabIndex.clamp(0, groups.length - 1);
    final credits = groups[index].credits;
    return SliverList.builder(
      itemCount: credits.length,
      itemBuilder: (context, i) => _filmoRow(credits[i], libraryMatchForCredit(credits[i], items)),
    );
  }

  /// One filmography row. Only the title of a title that's in your library is
  /// clickable — styled with Plezy's hover-underline link ([ClickableDetailText])
  /// and followed by an accented "On {server}" tag; the rest of the row is
  /// plain, selectable text.
  Widget _filmoRow(PersonCredit credit, MediaItem? libraryMatch) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium ?? const TextStyle();
    final muted = base.copyWith(color: base.color?.withValues(alpha: 0.6));
    final titleStyle = base.copyWith(fontWeight: FontWeight.w600);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        children: [
          SizedBox(width: 42, child: Text(credit.year?.toString() ?? '', style: muted)),
          if (libraryMatch != null)
            // Excluded from the surrounding SelectionArea so the link shows the
            // click cursor (not the text-select I-beam) and taps cleanly.
            Flexible(
              child: SelectionContainer.disabled(
                child: ClickableDetailText(
                  text: credit.title,
                  style: titleStyle,
                  onTap: () => unawaited(navigateToMediaItemDetails(context, libraryMatch, onRefresh: updateItem)),
                ),
              ),
            )
          else
            Flexible(
              child: Text(credit.title, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          if (credit.character case final character? when character.isNotEmpty)
            Flexible(
              child: Text('  ·  as $character', style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          if (libraryMatch != null)
            Flexible(
              child: Padding(padding: const EdgeInsets.only(left: 10), child: _onServerTag(theme, base)),
            ),
        ],
      ),
    );
  }

  /// The "On {server}" tag — a subtle mono-theme chip (faint fill), the app's
  /// own emphasis language rather than a foreign accent hue.
  Widget _onServerTag(ThemeData theme, TextStyle base) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          t.actor.onServer(server: widget.serverName ?? ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: base.copyWith(fontWeight: FontWeight.w600, fontSize: 12),
        ),
      ),
    );
  }

  static String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  /// Body below the header: In-your-library → Known For → Filmography, each
  /// present only when it has content. Loading/error/empty chrome shows only
  /// when there's nothing at all to render yet.
  List<Widget> _buildBodySlivers() {
    final slivers = <Widget>[];

    if (items.isNotEmpty) {
      slivers.add(_sectionHeaderSliver(t.actor.inYourLibrary));
      slivers.add(_buildLibraryGrid());
    }

    final knownFor = _onlinePage?.knownFor ?? const [];
    if (knownFor.isNotEmpty) {
      slivers.add(_sectionHeaderSliver(t.actor.knownFor));
      slivers.add(SliverToBoxAdapter(child: _buildKnownForRow(knownFor)));
    }

    final groups = _filmoGroups;
    if (groups.isNotEmpty) {
      slivers.add(_sectionHeaderSliver(t.actor.filmography));
      if (groups.length >= 2) slivers.add(_buildFilmoTabBar(groups));
      slivers.add(_buildFilmoList(groups));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    }

    if (slivers.isNotEmpty) return slivers;

    final stateSlivers = buildStateSlivers();
    if (stateSlivers.isNotEmpty) return stateSlivers;
    return [SliverEmptyState(message: emptyMessage, icon: emptyIcon)];
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformDetector.isTV()) return _buildTvScaffold();
    // Pointer platforms: SelectionArea lets the bio and filmography text be
    // selected/copied on desktop; taps on cards and clickable rows pass through.
    return SelectionArea(
      child: buildDetailScaffold(
        slivers: [
          CustomAppBar(title: Text(widget.actorName), pinned: true, actions: buildFocusableAppBarActions()),
          _buildActorHeader(),
          ..._buildBodySlivers(),
        ],
      ),
    );
  }

  /// TV: a fixed (pinned) hero above a scroll region holding the library grid
  /// and the credit rails. The hero lives OUTSIDE the scroll view, so focusing
  /// content can never scroll the actor info away — the structural fix for the
  /// "opens scrolled into the grid / section title hidden" bugs (S16-actor-dpad).
  Widget _buildTvScaffold() {
    return OverlaySheetHost(
      canPop: false,
      onSystemBack: () {
        if (BackKeyCoordinator.consumeIfHandled()) return;
        if (handleBackNavigation() && mounted) Navigator.pop(context);
      },
      child: Builder(
        builder: (hostContext) => Focus(
          // Catches a D-pad Back bubbling up from a focused rail (the strips
          // return `ignored` for Back) and pops; an open bio popup's own
          // FocusScope consumes Back first.
          onKeyEvent: (_, event) => handleBackKeyNavigation(hostContext, event),
          child: Scaffold(
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTvHero(),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => PrimaryScrollController(
                        controller: scrollController,
                        child: CustomScrollView(
                          primary: true,
                          slivers: _buildTvContentSlivers(viewportHeight: constraints.maxHeight),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The TV scroll region: the library grid, then one [PersonCreditStrip] rail
  /// per credit section (Known For, then filmography by role group).
  /// [viewportHeight] is the region's height under the pinned hero; the
  /// filmography is sized to it so its last rows never sit below the screen.
  List<Widget> _buildTvContentSlivers({required double viewportHeight}) {
    final slivers = <Widget>[];
    if (items.isNotEmpty) {
      slivers.add(_sectionHeaderSliver(t.actor.inYourLibrary));
      slivers.add(_buildLibraryGrid());
    }

    if (_hasKnownFor) {
      slivers.add(
        SliverToBoxAdapter(
          child: PersonCreditStrip(
            key: _knownForStripKey,
            title: t.actor.knownFor,
            credits: _knownForCredits,
            libraryMatchFor: (credit) => libraryMatchForCredit(credit, items),
            onOpen: _openCredit,
            onNavigateUp: () => _blockUp(_TvBlock.knownFor),
            onNavigateDown: () => _blockDown(_TvBlock.knownFor),
            debugLabel: 'actor_known_for',
          ),
        ),
      );
    }

    if (_hasFilmo) {
      slivers.add(
        SliverToBoxAdapter(
          child: PersonFilmographyList(
            key: _filmoListKey,
            title: t.actor.filmography,
            groups: _filmoGroups,
            libraryMatchFor: (credit) => libraryMatchForCredit(credit, items),
            onOpen: _openCredit,
            onServerLabel: widget.serverName == null ? null : t.actor.onServer(server: widget.serverName!),
            onNavigateUp: () => _blockUp(_TvBlock.filmo),
            onNavigateDown: () => _blockDown(_TvBlock.filmo),
            debugLabel: 'actor_filmography',
            height: viewportHeight.isFinite ? viewportHeight - _tvBottomSafeMargin : null,
          ),
        ),
      );
    }

    if (slivers.isEmpty) {
      final stateSlivers = buildStateSlivers();
      if (stateSlivers.isNotEmpty) return stateSlivers;
      return [SliverEmptyState(message: emptyMessage, icon: emptyIcon)];
    }
    slivers.add(const SliverSystemBottomInset());
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: _tvBottomSafeMargin)));
    return slivers;
  }

  /// Select on a credit card: open the owned library title; online-only credits
  /// (no local match) are inert — they have no local detail screen to open.
  void _openCredit(PersonCredit credit, MediaItem? match) {
    if (match == null) return;
    unawaited(navigateToMediaItemDetails(context, match, onRefresh: updateItem));
  }
}

/// The focusable content blocks below the pinned hero on the TV actor page, in
/// vertical order — the Up/Down D-pad chain walks the present ones in turn.
enum _TvBlock { grid, knownFor, filmo }

/// Fixed-height pinned host for the filmography [TabBar] (mirrors the library
/// browse tab's chips-bar delegate).
class _TabBarHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;

  const _TabBarHeaderDelegate(this.child);

  @override
  double get minExtent => kTextTabBarHeight;

  @override
  double get maxExtent => kTextTabBarHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox(height: kTextTabBarHeight, child: child);
  }

  @override
  bool shouldRebuild(covariant _TabBarHeaderDelegate oldDelegate) => child != oldDelegate.child;
}
