import 'package:flutter/material.dart';

import '../focus/dpad_navigator.dart';
import '../focus/key_event_utils.dart';
import '../media/media_item.dart';
import '../services/enrichment/person_online_page.dart';
import '../utils/scroll_utils.dart';
import 'focus_builders.dart';
import 'person_credit_card.dart';

/// A TV D-pad strip of [PersonCreditCard] posters (the actor page's "Known For"
/// row, and — per role group — its filmography, on TV).
///
/// Mirrors [CastMemberStrip]'s locked-focus model: ONE focus node owns a
/// highlighted index, Left/Right move the highlight (scrolling it into view),
/// Up/Down leave the strip, and Select opens the focused credit's library match
/// (inert when the credit isn't in your library). Unlike [CastMemberStrip] the
/// section TITLE lives INSIDE the focused unit, so when the strip scrolls into
/// view its title comes with it — the fix for the "section title scrolled off"
/// bug the earlier whole-section focus stop had.
///
/// TV-only: pointer platforms render Known For as a plain scrollable row (see
/// `actor_media_screen.dart`), so this widget assumes keyboard/D-pad focus.
class PersonCreditStrip extends StatefulWidget {
  final String title;
  final List<PersonCredit> credits;

  /// The local library item a credit resolves to when you own it, else null.
  final MediaItem? Function(PersonCredit credit) libraryMatchFor;

  /// Select on a credit: [match] is its owned library item (open it) or null.
  final void Function(PersonCredit credit, MediaItem? match) onOpen;

  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final String debugLabel;

  const PersonCreditStrip({
    super.key,
    required this.title,
    required this.credits,
    required this.libraryMatchFor,
    required this.onOpen,
    this.onNavigateUp,
    this.onNavigateDown,
    this.debugLabel = 'person_credit_strip',
  });

  // Sized so one rail (title + poster + caption) sits comfortably under the
  // pinned hero on TV without clipping — trimmed from the first redesign's 150
  // (then 130) so it reads a little smaller and the caption always fits. The
  // card title is capped at one line (below) so a long title can never wrap and
  // push the character/year out of the fixed caption (S17-actor-tv-rail-size).
  static const double _cardWidth = 120;
  static const double _cardGap = 12;
  static const double _rowVerticalPadding = 6;

  /// Poster (2:3) + the card's caption lines + the row padding. Kept a constant
  /// so the enclosing box reserves a stable height.
  static double get _rowHeight => _cardWidth * 3 / 2 + 78 + _rowVerticalPadding * 2;

  @override
  State<PersonCreditStrip> createState() => PersonCreditStripState();
}

class PersonCreditStripState extends State<PersonCreditStrip> {
  late final FocusNode _focusNode;
  final ScrollController _scrollController = ScrollController();
  int _focusedIndex = 0;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: widget.debugLabel)..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(PersonCreditStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.debugLabel != oldWidget.debugLabel) _focusNode.debugLabel = widget.debugLabel;
    if (widget.credits.isEmpty) {
      _focusedIndex = 0;
    } else if (_focusedIndex >= widget.credits.length) {
      _focusedIndex = widget.credits.length - 1;
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
      // Bring the WHOLE unit (title + posters) into the page's viewport, top
      // aligned, so the title is never scrolled off; then centre the poster.
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

  /// Focus this strip (from a neighbouring section). No-op when empty so focus
  /// never lands on a strip with nothing to highlight.
  void requestFocus() {
    if (widget.credits.isEmpty) return;
    _focusNode.requestFocus();
  }

  void _scrollToFocused() {
    if (!_scrollController.hasClients) return;
    scrollListToIndex(
      _scrollController,
      _focusedIndex,
      itemExtent: PersonCreditStrip._cardWidth + PersonCreditStrip._cardGap,
      leadingPadding: 16,
    );
  }

  void _moveFocus(int delta) {
    if (widget.credits.isEmpty) return;
    final target = (_focusedIndex + delta).clamp(0, widget.credits.length - 1).toInt();
    if (target == _focusedIndex) return;
    setState(() => _focusedIndex = target);
    _scrollToFocused();
  }

  void _activate(int index) {
    if (index < 0 || index >= widget.credits.length) return;
    if (_focusedIndex != index) setState(() => _focusedIndex = index);
    final credit = widget.credits[index];
    widget.onOpen(credit, widget.libraryMatchFor(credit));
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (key.isBackKey || widget.credits.isEmpty) return KeyEventResult.ignored;

    final selectResult = handleOneShotSelect(event, () => _activate(_focusedIndex));
    if (selectResult != KeyEventResult.ignored) return selectResult;
    if (!event.isActionable) return KeyEventResult.ignored;

    if (key.isLeftKey) {
      _moveFocus(-1);
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      _moveFocus(1);
      return KeyEventResult.handled;
    }
    if (key.isUpKey && widget.onNavigateUp != null) {
      widget.onNavigateUp!();
      return KeyEventResult.handled;
    }
    if (key.isDownKey && widget.onNavigateDown != null) {
      widget.onNavigateDown!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      focusNode: _focusNode,
      descendantsAreFocusable: false,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(widget.title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          ),
          SizedBox(
            height: PersonCreditStrip._rowHeight,
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: PersonCreditStrip._rowVerticalPadding),
              itemCount: widget.credits.length,
              itemBuilder: (context, index) {
                final credit = widget.credits[index];
                return Padding(
                  padding: const EdgeInsets.only(right: PersonCreditStrip._cardGap),
                  child: FocusBuilders.buildLockedFocusWrapper(
                    context: context,
                    isFocused: _focusNode.hasFocus && index == _focusedIndex,
                    borderRadius: 8,
                    onTap: () => _activate(index),
                    child: PersonCreditCard(credit: credit, width: PersonCreditStrip._cardWidth, titleMaxLines: 1),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
