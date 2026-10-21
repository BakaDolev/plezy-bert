import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../focus/focusable_action_bar.dart';
import '../focus/input_mode_tracker.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_role.dart';
import '../media/media_server_client.dart';
import '../services/media_list_playback_launcher.dart';
import '../services/watch_actions.dart';
import '../utils/actor_navigation.dart';
import '../utils/content_utils.dart';
import '../utils/desktop_window_padding.dart';
import '../utils/formatters.dart';
import '../utils/layout_constants.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/media_quality_labels.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../utils/video_player_navigation.dart';
import '../widgets/app_bar_back_button.dart';
import '../widgets/app_icon.dart';
import '../widgets/cast_member_strip.dart';
import '../widgets/cycling_media_backdrop.dart';
import '../widgets/fitting_title_text.dart';
import '../widgets/media_context_menu.dart';
import '../widgets/media_progress_bar.dart';
import '../widgets/media_rating_badge.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/overlay_sheet.dart';
import '../widgets/placeholder_container.dart';
import '../widgets/rasterized_gradient.dart';
import '../widgets/tv_spotlight_background.dart';
import 'media_detail_screen.dart';

/// Floor for the hero's computed height (see [_EpisodeDetailScreenState._heroHeight]).
/// Small enough to stay compact on a phone, tall enough that the kicker/
/// title/chips/still stack isn't cramped.
const double _minHeroHeight = 220;

/// Width past which the hero foreground switches from a stacked phone layout
/// (still above kicker/title/chips) to a side-by-side desktop row (still
/// beside kicker/title/chips).
const double _desktopHeroBreakpoint = 720;

/// Still-inset width caps for the phone-stacked and desktop-row hero
/// foreground layouts respectively.
const double _heroStillWidthPhone = 200;
const double _heroStillWidthDesktop = 300;

/// Caps the hero's foreground content block on very wide windows so the
/// title/chips don't stretch edge-to-edge on an ultrawide desktop window.
const double _heroContentMaxWidth = 960;

/// Upper bound (as a fraction of screen height) for [_EpisodeDetailScreenState._heroArtHeight],
/// mirroring [MediaDetailScreen]'s own `_maxHeroArtViewportFraction` (media_detail_screen.dart:109).
const double _maxHeroArtViewportFraction = 0.86;

/// Route to the per-episode detail page. Mirrors [mediaDetailRoute]:
/// Material on pointer platforms, a fade transition on TV. Returns `true`
/// when watch/rating state changed so the caller can refresh its list.
PageRoute<bool> episodeDetailRoute({required MediaItem metadata, bool isOffline = false}) {
  final page = EpisodeDetailScreen(metadata: metadata, isOffline: isOffline);
  if (!PlatformDetector.isTV()) return MaterialPageRoute<bool>(builder: (_) => page);
  return PageRouteBuilder<bool>(
    opaque: true,
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic),
      child: child,
    ),
    transitionDuration: AppDurations.animMedium,
    reverseTransitionDuration: AppDurations.animMedium,
  );
}

class EpisodeDetailScreen extends StatefulWidget {
  final MediaItem metadata;
  final bool isOffline;
  const EpisodeDetailScreen({super.key, required this.metadata, this.isOffline = false});

  @override
  State<EpisodeDetailScreen> createState() => _EpisodeDetailScreenState();
}

class _EpisodeDetailScreenState extends State<EpisodeDetailScreen> {
  MediaItem? _full;
  bool _loading = true;

  /// True once watch/rating state changed under this screen, so the route
  /// result tells the caller to refresh. Mirrors [MediaDetailScreen]'s
  /// `_watchStateChanged` (see media_detail_screen.dart).
  bool _changed = false;

  final GlobalKey<MediaContextMenuState> _moreMenuKey = GlobalKey<MediaContextMenuState>();

  /// TV focus: the two focusable sections on this screen — the action row and
  /// the cast strip (crew is plain text, never focusable). Mirrors
  /// [CatalogItemDetailScreen]'s `_actionBarKey`/`_castStripKey`/`_castSectionKey`
  /// pattern (catalog_item_detail_screen.dart) at the two-section scale this
  /// screen needs, rather than [MediaDetailScreen]'s many-section chain.
  final GlobalKey<FocusableActionBarState> _actionBarKey = GlobalKey<FocusableActionBarState>();
  final GlobalKey<CastMemberStripState> _castStripKey = GlobalKey<CastMemberStripState>();
  final GlobalKey _castSectionKey = GlobalKey();

  /// Drives [_buildHeroBackdropLayer]'s scroll-synced translate, non-TV only
  /// — mirrors [MediaDetailScreen]'s own `_scrollController` use in
  /// `_buildHeroBackdropLayer` (media_detail_screen.dart:4044-4129).
  final ScrollController _scrollController = ScrollController();

  MediaItem get _current => _full ?? widget.metadata;

  bool get _isResume => (_current.viewOffsetMs ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    _loadFull();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFull() async {
    try {
      final client = _clientFor(widget.metadata);
      final item = await client?.fetchItem(widget.metadata.id);
      if (!mounted) return;
      setState(() {
        if (item != null) _full = item;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  MediaServerClient? _clientFor(MediaItem item) {
    final id = item.serverId;
    if (id == null) return null;
    return context.getMediaClientForServer(ServerId(id));
  }

  Future<void> _play() async {
    final changed = await navigateToVideoPlayerWithRefresh(
      context,
      metadata: _current,
      isOffline: widget.isOffline,
      onRefresh: () {
        if (mounted) _loadFull();
      },
    );
    if (changed == true) _changed = true;
  }

  /// Marks the episode watched/unwatched via the shared [WatchActions]
  /// orchestrator (never the raw client — see watch_actions.dart), then
  /// refetches so [_current] reflects the server-confirmed state.
  Future<void> _toggleWatched() async {
    final watched = _current.isWatched; // MediaItem.isWatched (media_item.dart)
    final outcome = await WatchActions.setWatched(context, _current, watched: !watched, offline: widget.isOffline);
    if (outcome != WatchMarkOutcome.skipped && mounted) {
      _changed = true;
      unawaited(_loadFull());
    }
  }

  /// Shuffles the parent show's episodes. Mirrors [MediaDetailScreen]'s
  /// `_handleShufflePlayWithQueue` (media_detail_screen.dart): same offline
  /// guard/snackbar, same launcher call, same refresh-only-on-success — but
  /// does not set [_changed], matching that method (a shuffle launch alone
  /// isn't a watch/rating change).
  Future<void> _shuffleSeries() async {
    if (widget.isOffline) {
      showErrorSnackBar(context, t.mediaMenu.shuffleNotAvailableOffline);
      return;
    }
    final show = mediaDetailNavigationTargetFor(_current).metadata;
    final launcher = MediaListPlaybackLauncher.forItem(context, show);
    final result = await launcher.launchShuffledShow(metadata: show);
    if (result is PlayQueueSuccess && mounted) unawaited(_loadFull());
  }

  /// Navigates to the parent show/season, same stub-metadata push
  /// [navigateToMediaItemDetails] uses (media_navigation_helper.dart) — the
  /// pushed [MediaDetailScreen] loads its own full metadata on arrival.
  Future<void> _goToShow() async {
    final target = mediaDetailNavigationTargetFor(_current);
    final result = await Navigator.push<bool>(
      context,
      mediaDetailRoute(
        metadata: target.metadata,
        isOffline: widget.isOffline,
        initialSeasonIndex: target.initialSeasonIndex,
        initialSeasonId: target.initialSeasonId,
        initialEpisodeId: target.initialEpisodeId,
      ),
    );
    if (result == true && mounted) {
      _changed = true;
      unawaited(_loadFull());
    }
  }

  /// Whether [ep] has cast to show — the same condition [_buildCastSection]
  /// uses to omit the section entirely, kept here too so the action row only
  /// wires a D-pad bridge to a strip that actually exists.
  bool _hasCast(MediaItem ep) => (ep.roles ?? const <MediaRole>[]).isNotEmpty;

  /// Focuses (and scrolls to) the action row — the only place [CastMemberStrip]'s
  /// UP bridges back to.
  void _requestActionBarFocus() {
    _actionBarKey.currentState?.requestFocusOnFirst();
    final actionBarContext = _actionBarKey.currentContext;
    if (actionBarContext == null) return;
    // On TV the action row is the topmost focusable, with only the (visual) hero
    // above it in the SAME scroll view — and it autofocuses at offset 0 on load.
    // So returning to it should scroll the page fully back to the top, restoring
    // that load-time layout; `ensureVisible(alignment: 0.3)` instead left the row
    // 30% down with the hero half-scrolled off (S16-tv-episode-scroll).
    if (PlatformDetector.isTV()) {
      final position = Scrollable.maybeOf(actionBarContext)?.position;
      if (position != null) {
        unawaited(
          position.animateTo(
            position.minScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        );
        return;
      }
    }
    unawaited(
      Scrollable.ensureVisible(
        actionBarContext,
        alignment: 0.3,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }

  /// Focuses (and scrolls to) the cast strip. Only ever wired from the action
  /// row's `onNavigateDown` when [_hasCast] is true, so this is never called
  /// when the strip is absent from the tree.
  void _requestCastFocus() {
    _castStripKey.currentState?.requestFocus();
    final sectionContext = _castSectionKey.currentContext;
    if (sectionContext == null) return;
    unawaited(
      Scrollable.ensureVisible(
        sectionContext,
        alignment: 0.3,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }

  /// Play/Resume · Shuffle series · Watched · Go to show · ⋮ More.
  ///
  /// [FocusableActionBar] (focus/focusable_action_bar.dart) is the app-wide
  /// convention for a D-pad-focusable action row (also used by
  /// [MediaDetailScreen], [CatalogItemDetailScreen], the live-TV/library
  /// screens) — it owns per-button focus nodes, left/right cycling between
  /// them, and the up/down bridge callbacks below, rather than hand-rolling a
  /// new focus chain. Each button keeps its existing look via `child:`; the
  /// bar still wraps it in the shared focus-highlight decoration.
  Widget _buildActionRow(MediaItem ep) {
    return FocusableActionBar(
      key: _actionBarKey,
      spacing: 8,
      onNavigateDown: _hasCast(ep) ? _requestCastFocus : null,
      actions: [
        FocusableAction(
          debugLabel: 'episode_play',
          // Only the Play button autofocuses on TV, and only there — a
          // pointer/keyboard session leaves initial focus alone.
          autofocus: PlatformDetector.isTV(),
          onPressed: () => unawaited(_play()),
          // Icon-only, matching the show/movie screen's convention for a
          // non-show item (media_detail/action_buttons.dart's
          // `_getPlayButtonLabel` returns '' for episodes/movies, so its Play
          // button shows only the icon) — a text label here was the extra
          // width that overflowed this row at phone widths. `IconButton.filled`
          // (not `.filledTonal`, like the other buttons below) keeps Play
          // visually primary while matching their size; `tooltip` keeps the
          // resume/play label available to screen readers now that the
          // visible text is gone.
          child: IconButton.filled(
            onPressed: () => unawaited(_play()),
            icon: AppIcon(_isResume ? Symbols.resume_rounded : Symbols.play_arrow_rounded, fill: 1),
            tooltip: _isResume ? t.common.resume : t.common.play,
          ),
        ),
        FocusableAction(
          debugLabel: 'episode_shuffle',
          onPressed: () => unawaited(_shuffleSeries()),
          child: IconButton.filledTonal(
            onPressed: () => unawaited(_shuffleSeries()),
            icon: const AppIcon(Symbols.shuffle_rounded, fill: 1),
            tooltip: t.tooltips.shufflePlay,
          ),
        ),
        FocusableAction(
          debugLabel: 'episode_watched',
          onPressed: () => unawaited(_toggleWatched()),
          child: IconButton.filledTonal(
            onPressed: () => unawaited(_toggleWatched()),
            icon: AppIcon(ep.isWatched ? Symbols.remove_done_rounded : Symbols.check_rounded, fill: 1),
            tooltip: ep.isWatched ? t.tooltips.markAsUnwatched : t.tooltips.markAsWatched,
          ),
        ),
        FocusableAction(
          debugLabel: 'episode_go_to_show',
          onPressed: () => unawaited(_goToShow()),
          child: IconButton.filledTonal(
            onPressed: () => unawaited(_goToShow()),
            icon: const AppIcon(Symbols.tv_rounded, fill: 1),
            tooltip: t.mediaMenu.goToSeries,
          ),
        ),
        FocusableAction(
          debugLabel: 'episode_more',
          onPressed: () => _moreMenuKey.currentState?.showContextMenu(context),
          child: MediaContextMenu(
            key: _moreMenuKey,
            item: ep,
            // "View details" would just reopen this same episode page, so it
            // stays suppressed. "Go to series" is kept in the menu too (even
            // though the row above has a dedicated Go-to-show button) so it's
            // reachable from ⋮ More as well (user request 2026-09-08).
            suppressedActions: const {'details'},
            // Any refresh signal from the item's own ⋮More menu (this is
            // the only path to RATING — there's no dedicated rate button)
            // means something the caller should see changed, mirroring the
            // dedicated Watched button below setting `_changed` directly.
            onRefresh: (_) {
              if (!mounted) return;
              _changed = true;
              _loadFull();
            },
            child: IconButton.filledTonal(
              onPressed: () => _moreMenuKey.currentState?.showContextMenu(context),
              icon: const AppIcon(Symbols.more_vert_rounded, fill: 1),
            ),
          ),
        ),
      ],
    );
  }

  /// Hero kicker like "Season 2 · Episode 5", omitting either half that's
  /// null (specials carry no season and/or episode index) and the whole line
  /// when both are null. Spells both words out, unlike the retired
  /// abbreviated "S2 · E5" meta line this replaces — air date/runtime move to
  /// the metadata chip row below the title instead (see [_buildMetaChips]).
  String? _seasonEpisodeKicker(MediaItem ep) {
    final parts = <String>[
      if (ep.parentIndex != null) 'Season ${ep.parentIndex}',
      if (ep.index != null) 'Episode ${ep.index}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Cast strip for [ep]'s roles, or null when there are none — the section
  /// (including its header) is omitted entirely rather than rendering an
  /// empty strip, so an empty row never becomes a TV focus dead-end.
  Widget? _buildCastSection(MediaItem ep) {
    final roles = ep.roles ?? const <MediaRole>[];
    if (roles.isEmpty) return null;
    return Column(
      key: _castSectionKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text(t.discover.cast, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        CastMemberStrip(
          key: _castStripKey,
          imageClient: _clientFor(ep),
          members: [for (final r in roles) (name: r.tag, secondary: r.role, imagePath: r.thumbPath)],
          onMemberTap: (index) {
            final role = roles[index];
            if (role.id == null) return; // non-tappable when no person id
            navigateToActorMedia(context, role, ep);
          },
          onNavigateUp: _requestActionBarFocus,
        ),
      ],
    );
  }

  /// Director/writer lines for [ep], or null when there is neither — the
  /// section is omitted entirely (matching [_buildCastSection]'s
  /// null-returning convention) rather than rendering an empty block.
  /// Labels reuse the singular crew-credit keys `t.explore.creditRole.*`
  /// (the [CatalogItemDetailScreen] "Crew" section's convention: one
  /// singular label per role, values comma-joined) rather than
  /// `t.discover.director`/`directors`, since that pair has no matching
  /// writer key and this screen needs both roles labeled consistently.
  Widget? _buildCrew(MediaItem ep) {
    final rows = <Widget>[];
    final directors = ep.directors ?? const [];
    final writers = ep.writers ?? const [];
    final labelStyle = Theme.of(context).textTheme.bodySmall;
    if (directors.isNotEmpty) {
      rows.add(Text('${t.explore.creditRole.director}: ${directors.join(', ')}', style: labelStyle));
    }
    if (writers.isNotEmpty) {
      rows.add(Text('${t.explore.creditRole.writer}: ${writers.join(', ')}', style: labelStyle));
    }
    if (rows.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  /// 16:9 hero still, mirroring [EpisodeCard]'s `_buildEpisodeThumbnail`
  /// (episode_card.dart): same [OptimizedMediaImage.thumb] call, same
  /// [PlaceholderContainer] placeholder/error widgets. Falls back to the
  /// show's backdrop art (`grandparentArtPath` — already 16:9, unlike the
  /// poster-shaped `grandparentThumbPath`) when the episode has no still of
  /// its own. Offline downloads have no local-path plumbing into this screen
  /// yet ([episodeDetailRoute] takes no `localPosterPath`), so an offline
  /// episode without a resolvable network path just falls through to the
  /// placeholder rather than crashing.
  Widget _buildHeroStill(MediaItem ep) {
    final stillPath = ep.thumbPath ?? ep.grandparentArtPath;
    if (stillPath == null) {
      return const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32));
    }
    return OptimizedMediaImage.thumb(
      client: _clientFor(ep),
      imagePath: stillPath,
      fit: BoxFit.cover,
      placeholder: (context, url) => const PlaceholderContainer(),
      errorWidget: (context, url, error) =>
          const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32)),
    );
  }

  /// Hero still + resume progress bar overlaid on its bottom edge, mirroring
  /// [MediaProgressBar]'s use inside [WatchedIndicator] (watched_indicator.dart).
  Widget _buildHero(MediaItem ep) {
    final viewOffsetMs = ep.viewOffsetMs;
    final durationMs = ep.durationMs;
    final showResumeBar = viewOffsetMs != null && viewOffsetMs > 0 && (durationMs ?? 0) > 0;
    return AspectRatio(
      aspectRatio: GridLayoutConstants.episodeThumbnailAspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildHeroStill(ep),
          if (showResumeBar)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: MediaProgressBar(viewOffset: viewOffsetMs, duration: durationMs!),
            ),
        ],
      ),
    );
  }

  /// Bounded hero CONTENT height — the kicker/title/chips/still stack's own
  /// box, mirroring [MediaDetailScreen]'s hero sliver height at this hero's
  /// smaller, look-alike scale: a 16:9 box against the hero's own width,
  /// floored at [_minHeroHeight] so a narrow phone still gets a legible hero,
  /// and capped at 60% of the device screen height so it never crowds the
  /// action row/summary/cast below out of the initial viewport. Drives
  /// [_buildTvHeroSection]'s bounded `SizedBox` (TV) and the content
  /// `SizedBox` keyed `'episodeHeroSection'` in [_buildNonTvScaffold]
  /// (non-TV) — each caller wraps its own consumer in a [ClipRect] so content
  /// taller than this bound clips instead of throwing. The non-TV BACKDROP
  /// box is sized separately and taller — see [_heroArtHeight].
  double _heroHeight(double width, double screenHeight) {
    final maxHeight = math.max(_minHeroHeight, screenHeight * 0.6);
    return (width / (16 / 9)).clamp(_minHeroHeight, maxHeight);
  }

  /// Height of the non-TV backdrop paint box, deliberately TALLER than
  /// [_heroHeight]'s content box — mirroring [MediaDetailScreen]'s own
  /// `_heroArtHeight` (media_detail_screen.dart:4038-4042). Passing the same
  /// height to both the content box and the backdrop made the fanart end
  /// exactly where the action row begins, leaving a visible seam between
  /// them; painting the backdrop into this taller box instead means its
  /// gradient has room to fully dissolve into `scaffoldBackgroundColor`
  /// *below* the action row, so there is no edge left to see. A 16:9 box
  /// against the hero's own width, floored at the content height (never
  /// shorter, so it always covers at least the content box) and capped at
  /// [_maxHeroArtViewportFraction] of the screen height (the scrim ramps
  /// across this box, so a box that overshoots the window would still be
  /// translucent where the below-hero content begins).
  double _heroArtHeight(double width, double screenHeight) {
    final heroHeight = _heroHeight(width, screenHeight);
    final maxArtHeight = math.max(heroHeight, screenHeight * _maxHeroArtViewportFraction);
    return (width / (16 / 9)).clamp(heroHeight, maxArtHeight);
  }

  /// Backdrop + top-to-bottom scrim, painted as a background layer BEHIND the
  /// scrolling body (non-TV only — see [_buildTvHeroSection] for TV's
  /// self-contained bounded box). Mirrors [MediaDetailScreen]'s
  /// `_buildHeroBackdropLayer` (media_detail_screen.dart:4046-4129): a
  /// `Positioned` box pinned to the top of the [Stack], translated upward in
  /// lockstep with [_scrollController] so it scrolls away together with the
  /// hero foreground above it — without this, once the user scrolls past the
  /// hero, the backdrop would stay fixed on screen and bleed through any gap
  /// in the (unrelated) content now scrolled over it. `height` is expected to
  /// be [_heroArtHeight] (not [_heroHeight]) — the caller ([_buildNonTvScaffold])
  /// deliberately passes the taller art height so the gradient has room to
  /// fully dissolve into `scaffoldBackgroundColor` *below* the action row
  /// instead of ending exactly where it begins, which used to leave a visible
  /// seam. `containerAspect` below is derived from whatever `height` the
  /// caller passes, so the near-square art guard in `heroArtCandidates`/
  /// `heroRotationPaths` sees the art box's real aspect ratio either way.
  /// [ep.heroArtCandidates]/[ep.heroRotationPaths] already resolve an
  /// episode's own art first and fall back to the parent show's, so this
  /// picks up the show's fanart automatically.
  Widget _buildHeroBackdropLayer(BuildContext context, MediaItem ep, double width, double height) {
    final containerAspect = width / height;
    final heroArtPaths = ep.heroArtCandidates(containerAspectRatio: containerAspect);
    if (heroArtPaths.isEmpty) {
      return Positioned(top: 0, left: 0, right: 0, height: height, child: const PlaceholderContainer());
    }

    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: height,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _scrollController,
          builder: (context, child) {
            final offset = _scrollController.hasClients ? _scrollController.offset : 0.0;
            return Transform.translate(offset: Offset(0, -offset), child: child);
          },
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                blurArtwork(
                  CyclingMediaBackdrop(
                    mediaKey: ep.globalKey,
                    imagePaths: ep.heroRotationPaths(containerAspectRatio: containerAspect),
                    fallbackImagePaths: heroArtPaths,
                    client: _clientFor(ep),
                    allowNetwork: !widget.isOffline,
                    width: width,
                    height: height,
                    fallbackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                ),
                // Same eased ramp/stops as MediaDetailScreen's hero scrim
                // (media_detail_screen.dart:4107-4119) — see that method's doc
                // comment for why the curve/tail are shaped this way.
                RasterizedGradient(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      for (final a in const [0.20, 0.234, 0.325, 0.453, 0.60, 0.747, 0.875, 0.985, 0.998, 1.0])
                        bgColor.withValues(alpha: a),
                      bgColor,
                    ],
                    stops: [
                      for (final x in const [0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 0.9375, 1.0]) 0.94 * x,
                      1.0,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Stadium-pill metadata chip, mirroring [MediaDetailScreen]'s
  /// `_buildMetadataChip` (media_detail_screen.dart:927-957) at the
  /// plain-text-only scale this hero needs (no leading-icon variant).
  Widget _metaChip(BuildContext context, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.8),
        borderRadius: const BorderRadius.all(Radius.circular(100)),
      ),
      child: Text(
        text,
        style: TextStyle(color: colorScheme.onSecondaryContainer, fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// Air date, runtime, content rating, quality labels, then the rating-score
  /// pill — every non-null fact [ep] carries, mirroring the chip subset of
  /// [MediaDetailScreen]'s hero (`_buildRatingChips`,
  /// media_detail_screen.dart:964-981) minus the tappable user-rating chip
  /// (a new interactive control, out of scope for this look-alike redesign)
  /// and minus a genre row (episodes carry no genres of their own).
  List<Widget> _buildMetaChips(BuildContext context, MediaItem ep) {
    final airDate = ep.originallyAvailableAt;
    final contentRating = formatContentRating(ep.contentRating);
    return [
      if (airDate != null && airDate.isNotEmpty) _metaChip(context, formatFullDate(airDate)),
      if (ep.durationMs != null) _metaChip(context, formatDurationTextual(ep.durationMs!)),
      if (contentRating.isNotEmpty) _metaChip(context, contentRating),
      for (final label in buildMediaQualityLabels(ep)) _metaChip(context, label),
      // Upstream 2.20.0 replaced MediaRatingBadgeGroup.chip with InlineRatingBadges
      // (takes ratings, not the item, and no built-in chip background). Wrap it in a
      // _metaChip-matching container; InlineRatingBadges self-shrinks when empty, so
      // guard the chip on non-empty ratings to avoid an empty pill.
      if ((ep.ratings ?? const []).isNotEmpty)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.8),
            borderRadius: const BorderRadius.all(Radius.circular(100)),
          ),
          child: InlineRatingBadges(
            ratings: ep.ratings!,
            foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
    ];
  }

  /// Kicker + title + metadata chips, plus the still inset beside/above them.
  /// [isWide] picks the desktop side-by-side Row vs the phone stacked Column
  /// (see the responsive rules on [_buildTvHeroSection] and [_buildNonTvScaffold]).
  Widget _buildHeroForeground(BuildContext context, MediaItem ep, {required bool isWide}) {
    final theme = Theme.of(context);
    final kicker = _seasonEpisodeKicker(ep);
    final textShadows = [Shadow(color: theme.colorScheme.surface.withValues(alpha: 0.8), blurRadius: 8)];

    final titleColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (kicker != null) ...[
          Text(
            kicker,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              shadows: textShadows,
            ),
          ),
          const SizedBox(height: 4),
        ],
        FittingTitleText(
          ep.title ?? '',
          maxLines: 2,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, shadows: textShadows),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: _buildMetaChips(context, ep)),
      ],
    );

    final still = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: isWide ? _heroStillWidthDesktop : _heroStillWidthPhone),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _buildHero(ep)),
    );

    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          still,
          const SizedBox(width: 16),
          Expanded(child: titleColumn),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [still, const SizedBox(height: 12), titleColumn],
    );
  }

  /// The hero foreground's outer wrapper: bottom-left-aligned kicker/title/
  /// metadata-chip stack (+ still inset), width-capped at
  /// [_heroContentMaxWidth] on wide windows. No `FittedBox(scaleDown)`
  /// "safety net" here — a review found that was unreachable dead code (see
  /// [_buildHeroForegroundOverlay] for why the plain [Align] below never
  /// actually needed one) — dropped rather than kept as inert code.
  Widget _buildHeroForegroundBlock(BuildContext context, MediaItem ep, {required bool isWide}) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isWide ? _heroContentMaxWidth : double.infinity),
        child: _buildHeroForeground(context, ep, isWide: isWide),
      ),
    );
  }

  /// Positions [_buildHeroForegroundBlock] at the bottom-left of its
  /// enclosing bounded box — the shared wrapper both [_buildTvHeroSection]
  /// and [_buildNonTvScaffold]'s hero foreground use, as a `Stack` child
  /// alongside their own backdrop (TvSpotlightBackground / nothing — the
  /// non-TV backdrop lives separately behind the scroll view, see
  /// [_buildHeroBackdropLayer]).
  ///
  /// `Positioned(left, right, bottom)` with no `top`/`height` is deliberate:
  /// Flutter's Stack layout algorithm gives such a child UNBOUNDED height
  /// (its own default `BoxConstraints()`, unlike a Column/Row's
  /// loosened-but-still-bounded pass-through) — so kicker/title/chip content
  /// taller than the enclosing box overflows past it rather than throwing a
  /// RenderFlex assertion, and the enclosing `ClipRect` (see both callers)
  /// crops that overflow instead of letting it bleed into whatever comes
  /// next. A plain bounded `SizedBox`+`Align` here would make that overflow
  /// throw for real at narrow phone widths — that's why this stays a `Stack`
  /// child rather than the hero box's only content.
  Widget _buildHeroForegroundOverlay(BuildContext context, MediaItem ep, {required bool isWide}) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: _buildHeroForegroundBlock(context, ep, isWide: isWide),
        ),
      ),
    );
  }

  /// Phone (non-wide) hero foreground, laid out in NATURAL flow beneath a top
  /// clear zone rather than bottom-anchored inside a fixed box.
  ///
  /// The bottom-anchored [_buildHeroForegroundOverlay] + fixed [_heroHeight]
  /// box (a 16:9-of-width height) was tuned for the wide side-by-side row,
  /// where the still sits *beside* the title so the block is short. The phone
  /// STACKS the still *above* the kicker/title/chips (see
  /// [_buildHeroForeground]'s `isWide: false` column), which is taller than
  /// that box — so the bottom-anchored block used to overflow UPWARD past the
  /// box top, riding under the status bar and colliding with the overlaid
  /// round back button (S16-episode-phone-layout). Here the stack instead
  /// takes its own natural height, and the top padding reserves clearance for
  /// the status bar + the back button ([kToolbarHeight]) so the still/title/
  /// chips all sit cleanly below both. No fixed height means nothing to
  /// overflow. The taller backdrop art layer ([_heroArtHeight]) still paints
  /// behind and past this shorter content, so the scrim/seam treatment is
  /// unchanged.
  Widget _buildPhoneHeroForeground(BuildContext context, MediaItem ep) {
    final topClearance = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, topClearance, 16, 16),
      child: _buildHeroForeground(context, ep, isWide: false),
    );
  }

  /// TV's bounded-box hero: [TvSpotlightBackground] behind a bottom-left
  /// kicker/title/metadata-chip stack, with the episode still inset beside or
  /// above it (see [_buildHeroForegroundOverlay]). TV has no independently
  /// scrolling body to bleed behind — the reported bleed/seam bugs are
  /// non-TV only (see [_buildNonTvScaffold] and [_buildHeroBackdropLayer]) —
  /// so this stays a single fixed-height box, as it always has.
  ///
  /// Responsive: phone stacks the still above the title/chips; a window
  /// wider than [_desktopHeroBreakpoint] switches to a side-by-side row.
  ///
  /// `showInfo: false` on [TvSpotlightBackground] means it contributes only
  /// backdrop art + scrim (respecting the user's TV corner-backdrop setting)
  /// and doesn't duplicate the kicker/title/chips this method already draws.
  /// The action row keeps its existing shared position immediately below the
  /// hero rather than being layered inside this Stack —
  /// TvSpotlightBackground's own `contentBottom` offset assumes a full-screen
  /// box, and overlaying FocusableActionBar here would risk the TV D-pad
  /// focus/scroll-into-view chain the action row depends on (see
  /// `_requestActionBarFocus`).
  Widget _buildTvHeroSection(BuildContext context, MediaItem ep) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width <= 0) return const SizedBox.shrink();
        final height = _heroHeight(width, screenHeight);
        final isWide = width > _desktopHeroBreakpoint;

        return ClipRect(
          child: SizedBox(
            // Keyed so tests can assert the hero's actual bounded height
            // (see [_heroHeight]) without guessing which ClipRect/SizedBox
            // in the tree is the hero's own — `blurArtwork` below adds
            // another ClipRect around just the backdrop image.
            key: const Key('episodeHeroSection'),
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TvSpotlightBackground(
                  item: ep,
                  client: _clientFor(ep),
                  showInfo: false,
                  allowNetwork: !widget.isOffline,
                ),
                _buildHeroForegroundOverlay(context, ep, isWide: isWide),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The action row / loading-summary / summary / cast / crew block below the
  /// hero, shared verbatim by [_buildTvScaffold] and [_buildNonTvScaffold].
  Widget _buildBelowHeroContent(BuildContext context, MediaItem ep) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildActionRow(ep),
          const SizedBox(height: 16),
          if (_loading && _current.summary == null)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
          if (_current.summary != null && _current.summary!.isNotEmpty)
            Text(_current.summary!, style: Theme.of(context).textTheme.bodyMedium),
          ?_buildCastSection(_current),
          ?_buildCrew(_current),
        ],
      ),
    );
  }

  /// TV build: the hero backdrop bleeds to the very top edge, matching the
  /// non-TV scaffold and [MediaDetailScreen]'s TV hero. It previously sat under
  /// a bare [AppBar], which rendered a black bar across the top of the TV page
  /// (S16-tv-episode-blackbar). There's no visible back button — TV back is the
  /// D-pad Back key, owned by the screen-level [Focus]/[OverlaySheetHost] in
  /// [build] (matching the TV detail-screen convention). `SafeArea(top: false)`
  /// lets the backdrop bleed up while still insetting the scrolling content
  /// from the bottom overscan/navigation area.
  Widget _buildTvScaffold(BuildContext context, MediaItem ep) {
    return Scaffold(
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_buildTvHeroSection(context, ep), _buildBelowHeroContent(context, ep)],
          ),
        ),
      ),
    );
  }

  /// Non-TV build: mirrors [MediaDetailScreen]'s hero structure
  /// (media_detail_screen.dart, `build`, ~3007-3043) — a bare (app-bar-less)
  /// [Scaffold] whose body is a [Stack] with [_buildHeroBackdropLayer] as a
  /// background layer BEHIND a scrolling body, so the backdrop bleeds to the
  /// very top of the window (no `AppBar`/back-button strip above it, unlike
  /// TV's [_buildTvScaffold]) — fixing the "black bar above the backdrop"
  /// bug. The backdrop layer is sized to [_heroArtHeight], deliberately
  /// TALLER than the CONTENT box below (sized to [_heroHeight]), so its scrim
  /// fades continuously into `scaffoldBackgroundColor` *below* the action row
  /// instead of ending exactly where it begins — fixing the reported
  /// horizontal seam between the metadata chips and the action row. The back
  /// button overlays the backdrop directly (mirroring
  /// media_detail_screen.dart:3228-3239) rather than living in an `AppBar`.
  Widget _buildNonTvScaffold(BuildContext context, MediaItem ep) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    final heroHeight = _heroHeight(width, size.height);
    final heroArtHeight = _heroArtHeight(width, size.height);
    final isWide = width > _desktopHeroBreakpoint;

    return Scaffold(
      body: Stack(
        children: [
          _buildHeroBackdropLayer(context, ep, width, heroArtHeight),
          SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wide (desktop) hero: fixed [_heroHeight] box with the
                // foreground bottom-anchored over the (separate) backdrop
                // layer; a single-child Stack + ClipRect so an over-long
                // title/chip row clips instead of throwing. Phone hero: the
                // stack takes its natural height beneath a top clear zone —
                // see [_buildPhoneHeroForeground] for why the fixed box was
                // wrong for the taller phone stack (S16-episode-phone-layout).
                if (isWide)
                  ClipRect(
                    child: SizedBox(
                      // Keyed so tests can assert the hero's actual bounded
                      // height (see [_heroHeight]) without guessing which box
                      // in the tree is the hero's own.
                      key: const Key('episodeHeroSection'),
                      width: double.infinity,
                      height: heroHeight,
                      child: Stack(children: [_buildHeroForegroundOverlay(context, ep, isWide: isWide)]),
                    ),
                  )
                else
                  SizedBox(
                    key: const Key('episodeHeroSection'),
                    width: double.infinity,
                    child: _buildPhoneHeroForeground(context, ep),
                  ),
                _buildBelowHeroContent(context, ep),
                // Bottom safe-area clearance for the home indicator,
                // mirroring MediaDetailScreen's trailing SliverPadding
                // (media_detail_screen.dart:3192).
                SizedBox(height: MediaQuery.paddingOf(context).bottom),
              ],
            ),
          ),
          // Overlaid back button, mirroring media_detail_screen.dart:3228-3239.
          Positioned(
            top: 0,
            left: 0,
            child: DesktopAppBarHelper.buildAdjustedLeading(
              AppBarBackButton(style: BackButtonStyle.circular, onPressed: () => Navigator.pop(context, _changed)),
              context: context,
            )!,
          ),
        ],
      ),
    );
  }

  /// System/route back when no sheet is open and a native pop is blocked
  /// (TV/keyboard back). Dedups against the focused dpad key path via
  /// [BackKeyCoordinator], mirroring [CatalogItemDetailScreen._handleSystemBack].
  void _handleSystemBack() {
    if (BackKeyCoordinator.consumeIfHandled()) return;
    Navigator.pop(context, _changed);
  }

  @override
  Widget build(BuildContext context) {
    final ep = _current;

    // Back handling mirrors [CatalogItemDetailScreen] (and [MediaDetailScreen]):
    // wrap in an [OverlaySheetHost] so the ⋮More menu presents as an overlay
    // sheet (not a route-based modal), and let the host own the system/route
    // back path. Without the host this screen fell back to
    // [showModalBottomSheet], hitting the route-based back-button race on
    // Android TV where Back exited the whole page instead of dismissing the
    // open More sheet (S16-tv-more-back). With a sheet open the host closes it;
    // with none open, TV/keyboard back runs [_handleSystemBack] (canPop false)
    // while native mobile back / iOS swipe-back pop the route (canPop true).
    final blockSystemBack = PlatformDetector.isTV() || InputModeTracker.shouldBlockSystemBack(context);
    return OverlaySheetHost(
      canPop: !blockSystemBack,
      onSystemBack: _handleSystemBack,
      child: Builder(
        // Below the host, so the ⋮More menu's `showAdaptive` finds it (and the
        // screen-level Focus catches any dpad Back the sheet's own FocusScope
        // didn't already consume while open).
        builder: (hostContext) => Focus(
          onKeyEvent: (_, event) => handleBackKeyNavigation(hostContext, event, result: _changed),
          child: PlatformDetector.isTV() ? _buildTvScaffold(hostContext, ep) : _buildNonTvScaffold(hostContext, ep),
        ),
      ),
    );
  }
}
