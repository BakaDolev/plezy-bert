import 'package:flutter/material.dart';

import '../focus/dpad_navigator.dart';
import '../focus/key_event_utils.dart';
import '../media/media_item.dart';
import '../services/enrichment/person_online_page.dart';
import '../utils/scroll_utils.dart';
import 'focus_builders.dart';

/// A TV D-pad vertical list of an actor's filmography, role-tabbed like the
/// desktop page (`year · title · as character`) instead of poster rails — the
/// compact reading list the desktop shows, made 10-foot navigable.
///
/// Locked-focus model, mirroring [PersonCreditStrip] but VERTICAL: one focus
/// node owns the active role tab ([_groupIndex]) and the highlighted row
/// ([_rowIndex]). Left/Right switch role tabs (when there are ≥2 groups),
/// Up/Down move the row — leaving the list at either end via [onNavigateUp] /
/// [onNavigateDown] — and Select opens the focused credit's library match
/// (inert when the title isn't in your library). The "Filmography" heading and
/// the role tabs sit at the top of the focused unit, so when the list scrolls
/// into view its heading comes with it (never scrolled off).
///
/// TV-only: pointer platforms render the filmography as the desktop tabbed
/// [SliverList] in `actor_media_screen.dart`, so this widget assumes D-pad
/// focus and carries no hover affordances.
class PersonFilmographyList extends StatefulWidget {
  /// Localized "Filmography" heading.
  final String title;

  /// The credit groups that have titles, in Plex's order (non-empty).
  final List<PersonCreditGroup> groups;

  /// The local library item a credit resolves to when you own it, else null.
  final MediaItem? Function(PersonCredit credit) libraryMatchFor;

  /// Select on a row: [match] is its owned library item (open it) or null.
  final void Function(PersonCredit credit, MediaItem? match) onOpen;

  /// The "On {server}" tag text shown on owned rows, or null to omit the tag.
  final String? onServerLabel;

  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final String debugLabel;

  /// The whole unit's height (heading + tabs + rows), with the rows filling
  /// what's left, or null for a fixed [_visibleRows] window. The TV actor page
  /// passes its scroll viewport so the unit, scrolled to the top, sits fully on
  /// screen under the pinned hero.
  final double? height;

  const PersonFilmographyList({
    super.key,
    required this.title,
    required this.groups,
    required this.libraryMatchFor,
    required this.onOpen,
    this.onServerLabel,
    this.onNavigateUp,
    this.onNavigateDown,
    this.debugLabel = 'person_filmography_list',
    this.height,
  });

  /// One row's fixed height (a single `year · title · character` line). Fixed so
  /// the list can scroll to a row by index and reserve a stable window.
  static const double _rowHeight = 40;

  /// Rows visible in the scroll window before it scrolls internally. Compact on
  /// purpose — a text list is far shorter than the old poster rails.
  static const int _visibleRows = 7;

  static String capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  @override
  State<PersonFilmographyList> createState() => PersonFilmographyListState();
}

class PersonFilmographyListState extends State<PersonFilmographyList> {
  late final FocusNode _focusNode;
  final ScrollController _scrollController = ScrollController();
  int _groupIndex = 0;
  int _rowIndex = 0;

  List<PersonCredit> get _credits =>
      (_groupIndex >= 0 && _groupIndex < widget.groups.length) ? widget.groups[_groupIndex].credits : const [];

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: widget.debugLabel)..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(PersonFilmographyList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.debugLabel != oldWidget.debugLabel) _focusNode.debugLabel = widget.debugLabel;
    if (widget.groups.isEmpty) {
      _groupIndex = 0;
      _rowIndex = 0;
    } else {
      if (_groupIndex >= widget.groups.length) _groupIndex = widget.groups.length - 1;
      final max = _credits.length - 1;
      if (_rowIndex > max) _rowIndex = max < 0 ? 0 : max;
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    setState(() {});
    if (_focusNode.hasFocus) {
      // Bring the whole unit (heading + tabs + rows) into view, top aligned, so
      // the heading is never scrolled off; then scroll to the focused row.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_focusNode.hasFocus) return;
        final ctx = _focusNode.context;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
        _scrollToFocused();
      });
    }
  }

  /// Focus this list (from a neighbouring section). No-op when empty so focus
  /// never lands on a list with nothing to highlight.
  void requestFocus() {
    if (widget.groups.isEmpty) return;
    _focusNode.requestFocus();
  }

  void _scrollToFocused() {
    if (!_scrollController.hasClients) return;
    scrollListToIndex(_scrollController, _rowIndex, itemExtent: PersonFilmographyList._rowHeight, leadingPadding: 0);
  }

  void _moveRow(int delta) {
    final credits = _credits;
    if (credits.isEmpty) return;
    final target = (_rowIndex + delta).clamp(0, credits.length - 1).toInt();
    if (target == _rowIndex) return;
    setState(() => _rowIndex = target);
    _scrollToFocused();
  }

  void _switchTab(int delta) {
    if (widget.groups.length < 2) return;
    final target = (_groupIndex + delta).clamp(0, widget.groups.length - 1).toInt();
    if (target == _groupIndex) return;
    setState(() {
      _groupIndex = target;
      _rowIndex = 0;
    });
    _scrollToFocused();
  }

  void _activate() {
    final credits = _credits;
    if (_rowIndex < 0 || _rowIndex >= credits.length) return;
    final credit = credits[_rowIndex];
    widget.onOpen(credit, widget.libraryMatchFor(credit));
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (key.isBackKey || widget.groups.isEmpty) return KeyEventResult.ignored;

    final selectResult = handleOneShotSelect(event, _activate);
    if (selectResult != KeyEventResult.ignored) return selectResult;
    if (!event.isActionable) return KeyEventResult.ignored;

    if (key.isLeftKey) {
      _switchTab(-1);
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      _switchTab(1);
      return KeyEventResult.handled;
    }
    if (key.isUpKey) {
      if (_rowIndex > 0) {
        _moveRow(-1);
      } else if (widget.onNavigateUp != null) {
        widget.onNavigateUp!();
      }
      return KeyEventResult.handled;
    }
    if (key.isDownKey) {
      if (_rowIndex < _credits.length - 1) {
        _moveRow(1);
      } else if (widget.onNavigateDown != null) {
        widget.onNavigateDown!();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credits = _credits;
    final hasFocus = _focusNode.hasFocus;
    final height = widget.height;
    final rows = ListView.builder(
      controller: _scrollController,
      itemExtent: PersonFilmographyList._rowHeight,
      padding: EdgeInsets.zero,
      itemCount: credits.length,
      itemBuilder: (context, index) => _buildRow(theme, credits[index], index, hasFocus),
    );

    final unit = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(widget.title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (widget.groups.length >= 2) _buildTabs(theme),
        if (height != null)
          Expanded(child: rows)
        else
          SizedBox(height: PersonFilmographyList._rowHeight * PersonFilmographyList._visibleRows, child: rows),
      ],
    );

    return Focus(
      focusNode: _focusNode,
      descendantsAreFocusable: false,
      onKeyEvent: _handleKeyEvent,
      child: height != null ? SizedBox(height: height, child: unit) : unit,
    );
  }

  Widget _buildTabs(ThemeData theme) {
    final base = theme.textTheme.labelLarge ?? const TextStyle();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 18,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < widget.groups.length; i++)
            Text(
              '${PersonFilmographyList.capitalize(widget.groups[i].label)} (${widget.groups[i].credits.length})',
              style: i == _groupIndex
                  ? base.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)
                  : base.copyWith(color: base.color?.withValues(alpha: 0.55)),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(ThemeData theme, PersonCredit credit, int index, bool listHasFocus) {
    final base = theme.textTheme.bodyMedium ?? const TextStyle();
    final muted = base.copyWith(color: base.color?.withValues(alpha: 0.6));
    final titleStyle = base.copyWith(fontWeight: FontWeight.w600);
    final match = widget.libraryMatchFor(credit);
    final character = credit.character;

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 42, child: Text(credit.year?.toString() ?? '', style: muted)),
          Flexible(
            child: Text(credit.title, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (character != null && character.isNotEmpty)
            Flexible(
              child: Text('  ·  as $character', style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          if (match != null && widget.onServerLabel != null)
            Padding(padding: const EdgeInsets.only(left: 10), child: _onServerTag(theme, base)),
        ],
      ),
    );

    return FocusBuilders.buildLockedFocusWrapper(
      context: context,
      isFocused: listHasFocus && index == _rowIndex,
      borderRadius: 6,
      onTap: match == null ? null : () => widget.onOpen(credit, match),
      child: row,
    );
  }

  Widget _onServerTag(ThemeData theme, TextStyle base) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          widget.onServerLabel!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: base.copyWith(fontWeight: FontWeight.w600, fontSize: 12),
        ),
      ),
    );
  }
}
