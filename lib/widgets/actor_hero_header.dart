import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/app_locale_utils.dart';
import '../i18n/strings.g.dart';
import '../media/media_server_client.dart';
import '../services/enrichment/actor_info.dart';
import '../theme/mono_tokens.dart';
import '../utils/layout_constants.dart';
import '../utils/media_image_helper.dart';
import '../focus/focusable_wrapper.dart';
import 'collapsible_text.dart';
import 'fitting_title_text.dart';
import 'media_card.dart' show SkeletonLoader;
import 'optimized_media_image.dart';

/// Clean, Plezy-styled hero for the actor media screen: a crisp portrait
/// card beside name/occupation/born-died facts, with a collapsible bio
/// underneath — all sitting directly on the screen's plain theme
/// background.
///
/// Deliberately NOT the earlier full-bleed blurred-portrait-as-artwork
/// backdrop (the portrait enlarged behind a scrim looked like the photo was
/// just stretched as wallpaper). This is a normal detail header: a portrait
/// card and text, the same shape as [CastMemberStrip]'s cards, not a Plex
/// clone.
///
/// Pure and stateless (all enrichment data is injected) so it can sit inside
/// a `ValueListenableBuilder` scoped to just the enrichment notifier —
/// enrichment landing rebuilds this header only, never the paginated media
/// grid below it (Task 8 design). Wiring real enrichment data happens in a
/// later task; until then callers pass `enrichment: null,
/// isEnrichmentLoading: false` and the hero renders portrait/name only.
class ActorHeroHeader extends StatelessWidget {
  final String actorName;
  final String? portraitPath;

  /// No longer rendered — Plex's own actor header carries neither a
  /// character kicker nor a title-count line. Kept (unused) so
  /// `ActorMediaScreen`'s existing call site compiles unchanged.
  final String? characterName;
  final int titleCount;

  final ActorInfo? enrichment;
  final bool isEnrichmentLoading;
  final bool isTv;

  /// Client used to resolve [portraitPath] through the right server's image
  /// transcoder. Nullable like [OptimizedMediaImage.client] itself — tests
  /// and offline/orphaned-server callers can omit it.
  final MediaServerClient? mediaClient;

  /// Full ISO birth date from the Plex Discover profile ("1969-07-30"), when
  /// available — richer than [ActorInfo.bornYear] (which the Wikidata fallback
  /// gives as a year only). Drives the full born line: formatted date + age.
  final String? bornOn;

  /// Birthplace from the Plex Discover profile, when available.
  final String? birthPlace;

  /// Instagram profile URL from the Plex Discover profile, when available.
  final String? instagramUrl;

  /// Makes the bio a D-pad focus target (TV). When non-null the bio drops out
  /// of the header's [ExcludeFocus] and becomes a focusable "Read more" target
  /// that opens the full bio in a scrollable popup ([onBioReadMore]) — a long
  /// bio can't be read via inline expand on a focus-driven 10-foot UI
  /// (S16-actor-bio-toggle / S16-actor-dpad). The callbacks wire it into the
  /// screen's focus chain. Null on pointer platforms, where the bio is the
  /// inline show-more/less [CollapsibleText] and stays out of traversal.
  final FocusNode? bioFocusNode;
  final VoidCallback? onBioReadMore;
  final VoidCallback? onBioNavigateDown;
  final VoidCallback? onBioNavigateUp;

  const ActorHeroHeader({
    super.key,
    required this.actorName,
    this.portraitPath,
    this.characterName,
    required this.titleCount,
    this.enrichment,
    this.isEnrichmentLoading = false,
    this.isTv = false,
    this.mediaClient,
    this.bornOn,
    this.birthPlace,
    this.instagramUrl,
    this.bioFocusNode,
    this.onBioReadMore,
    this.onBioNavigateDown,
    this.onBioNavigateUp,
  });

  /// Bio lines previewed in the pinned TV hero; "Read more" opens the rest.
  static const int _tvBioPreviewLines = 2;

  /// Portrait card width (2:3 aspect, so height is 1.5×). Bigger on TV to
  /// match its larger text scale; a bit smaller on narrow (phone) widths so
  /// it never crowds out the text once the layout stacks.
  double _portraitWidth(bool narrow) {
    // Compact on TV: the hero is pinned above the content rails, so keep it
    // short (a portrait no taller than the facts + bio beside it) to leave the
    // rails room.
    if (isTv) return 112;
    return narrow ? 110 : 150;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bioSection = _buildBioSection(theme);

    // TV: a COMPACT hero (the pinned top of the actor page) — portrait on the
    // left, and name/facts + the bio "Read more" stacked to its right, so the
    // hero stays short and leaves the content rails below plenty of room.
    if (isTv) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildPortrait(context, false),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildFacts(theme),
                  if (bioSection != null) ...[const SizedBox(height: 6), bioSection],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = ScreenBreakpoints.isMobile(constraints.maxWidth);
              final portrait = _buildPortrait(context, narrow);
              final facts = _buildFacts(theme);
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [portrait, const SizedBox(height: 12), facts],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  portrait,
                  const SizedBox(width: 16),
                  Expanded(child: facts),
                ],
              );
            },
          ),
          if (bioSection != null) ...[const SizedBox(height: 12), bioSection],
        ],
      ),
    );
  }

  Widget _buildPortrait(BuildContext context, bool narrow) {
    final width = _portraitWidth(narrow);
    return ClipRRect(
      borderRadius: BorderRadius.circular(tokens(context).radiusMd),
      child: OptimizedMediaImage(
        client: mediaClient,
        imagePath: portraitPath,
        width: width,
        height: width * 3 / 2,
        fit: BoxFit.cover,
        imageType: ImageType.avatar,
        fallbackIcon: Symbols.person_rounded,
      ),
    );
  }

  Widget _buildFacts(ThemeData theme) {
    final occupationLine = _occupationLine();
    final bornLine = _bornLine();
    final factStyle = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittingTitleText(
          actorName,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          maxLines: 2,
        ),
        if (occupationLine != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(occupationLine, style: factStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
          )
        else if (isEnrichmentLoading)
          Padding(padding: const EdgeInsets.only(top: 6), child: _skeletonLine(width: 140)),
        if (bornLine != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(bornLine, style: factStyle),
          )
        else if (isEnrichmentLoading)
          Padding(padding: const EdgeInsets.only(top: 4), child: _skeletonLine(width: 100)),
        if (_buildInstagramLink(theme) case final link?) Padding(padding: const EdgeInsets.only(top: 6), child: link),
      ],
    );
  }

  Widget _skeletonLine({required double width}) => SkeletonLoader(
    borderRadius: BorderRadius.circular(4),
    child: SizedBox(height: 12, width: width),
  );

  /// Occupations read like "Actor, Producer" — a plain comma-space join
  /// (not `toBulletedString`'s middot separator, which is the list-of-facts
  /// convention used elsewhere, not a plain-English list like this one).
  String? _occupationLine() {
    final occupations = enrichment?.occupations ?? const <String>[];
    return occupations.isEmpty ? null : occupations.join(', ');
  }

  /// The born line, preferring the Plex Discover profile's full birth date:
  /// "July 30, 1969 · 57 · Tasmania, Australia" (locale-formatted date ·
  /// computed age · birthplace). Falls back to the year-only Wikidata forms —
  /// "Born {year}" while alive, "{born}–{died}" (en dash, years) once a death
  /// year is known — then to a lone birthplace, then to nothing.
  ///
  /// Every part is dropped when its datum is absent, so the line is never
  /// blank or half-formed: the same never-show-wrong-data posture as the
  /// enrichment service itself, applied at render time.
  String? _bornLine() {
    final bornDate = _parseIsoDate(bornOn);
    if (bornDate != null) {
      final parts = <String>[
        DateFormat.yMMMMd(_intlLocale).format(bornDate),
        if (_ageYears(bornDate) case final age?) '$age',
        ?_trimmedOrNull(birthPlace),
      ];
      return parts.join(' · ');
    }
    final born = enrichment?.bornYear;
    if (born == null) return _trimmedOrNull(birthPlace);
    final died = enrichment?.diedYear;
    if (died == null) return t.actor.bornYear(year: born);
    return '$born–$died';
  }

  String get _intlLocale => LocaleSettings.currentLocale.intlLocaleName;

  static String? _trimmedOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static DateTime? _parseIsoDate(String? iso) {
    final trimmed = iso?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return DateTime.tryParse(trimmed);
  }

  /// Whole years from [born] to the death year (age at death) when one is
  /// known, else to today. Null for an implausible value so a wrong age is
  /// never shown.
  int? _ageYears(DateTime born) {
    final died = enrichment?.diedYear;
    final int age;
    if (died != null) {
      age = died - born.year;
    } else {
      final now = DateTime.now();
      final hadBirthday = now.month > born.month || (now.month == born.month && now.day >= born.day);
      age = now.year - born.year - (hadBirthday ? 0 : 1);
    }
    return (age >= 0 && age < 200) ? age : null;
  }

  /// External Instagram link (Plex profile), or null when there is no URL.
  /// A pointer-only affordance (hover cursor + underline). Omitted on TV: it is
  /// never a D-pad target there, and the pinned TV hero can't spare the row.
  Widget? _buildInstagramLink(ThemeData theme) {
    if (isTv) return null;
    final url = _trimmedOrNull(instagramUrl);
    if (url == null) return null;
    return _HeaderExternalLink(
      icon: Symbols.open_in_new_rounded,
      label: _instagramHandle(url),
      color: theme.colorScheme.primary,
      onTap: () => _openUrl(url),
    );
  }

  /// "@handle" from an Instagram URL's last path segment, or the plain label
  /// "Instagram" when none can be derived.
  static String _instagramHandle(String url) {
    final segments = Uri.tryParse(url)?.pathSegments.where((s) => s.trim().isNotEmpty).toList() ?? const [];
    return segments.isEmpty ? 'Instagram' : '@${segments.last}';
  }

  static Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort: a failed launch must never throw out of a tap handler.
    }
  }

  /// Returns null when there's nothing to show — no bio, and not loading —
  /// so the caller can skip reserving any space for it.
  Widget? _buildBioSection(ThemeData theme) {
    final bio = enrichment?.bio;
    if (bio != null && bio.isNotEmpty) {
      // TV: a focusable "Read more" opening the full bio in a scrollable popup
      // (a long bio can't be read via inline expand on a focus-driven UI).
      if (isTv && bioFocusNode != null && onBioReadMore != null) {
        return _buildTvBio(theme, bio);
      }
      // Phone/desktop: inline show-more/less, tapped directly.
      return CollapsibleText(text: bio, maxLines: 4, style: theme.textTheme.bodyMedium);
    }
    if (isEnrichmentLoading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _skeletonLine(width: double.infinity),
          const SizedBox(height: 6),
          _skeletonLine(width: double.infinity),
          const SizedBox(height: 6),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: 0.6,
            child: _skeletonLine(width: double.infinity),
          ),
        ],
      );
    }
    return null;
  }

  /// TV bio: a short preview of the bio plus a focusable "Read more" that opens
  /// the full text in a scrollable popup ([onBioReadMore]). The "Read more" is
  /// the top of the actor page's TV D-pad chain (down → next section, up → top).
  Widget _buildTvBio(ThemeData theme, String bio) {
    final linkColor = theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(bio, style: theme.textTheme.bodyMedium, maxLines: _tvBioPreviewLines, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        FocusableWrapper(
          focusNode: bioFocusNode,
          onSelect: onBioReadMore,
          onNavigateUp: onBioNavigateUp,
          onNavigateDown: onBioNavigateDown,
          disableScale: true,
          useBackgroundFocus: true,
          borderRadius: 8,
          scrollAlignment: 0.0,
          semanticLabel: t.actor.readMore,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.actor.readMore,
                  style: theme.textTheme.labelLarge?.copyWith(color: linkColor, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 2),
                Icon(Symbols.chevron_right_rounded, size: 18, color: linkColor),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A compact pointer-only external link (icon + label) with a hover underline
/// and click cursor, mirroring [ClickableDetailText]'s pointer affordance for
/// the actor header's Instagram line. Deliberately not focusable — the header
/// is decorative on TV — so it carries no D-pad handling.
class _HeaderExternalLink extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _HeaderExternalLink({required this.icon, required this.label, required this.onTap, this.color});

  @override
  State<_HeaderExternalLink> createState() => _HeaderExternalLinkState();
}

class _HeaderExternalLinkState extends State<_HeaderExternalLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: widget.color,
      decoration: _hovered ? TextDecoration.underline : null,
      decorationColor: widget.color,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, size: 16, color: widget.color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(widget.label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
