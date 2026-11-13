import 'dart:async';

import 'package:flutter/material.dart';

import '../../../utils/scroll_utils.dart';
import '../../../widgets/overlay_sheet.dart';
import 'sheet_column_header.dart';

/// Per-row handle handed to [SheetSelectionColumn.itemBuilder].
abstract class SheetSelectionColumnScope {
  /// Key for the row at [index]. Only the first row is keyed, so the one-time
  /// initial scroll can measure a real item height.
  Key? keyFor(int index);

  /// Focus node for the row at [index]. Only the current row (the first row
  /// when nothing is current) gets one: it is where the remote starts when the
  /// sheet opens.
  FocusNode? focusNodeFor(int index);

  /// Runs an async selection: re-entrant taps are ignored while one is in
  /// flight, a progress bar is shown meanwhile, and the sheet is closed once
  /// [action] completes.
  void runExclusive(Future<void> Function() action);
}

/// Shared scaffold for the selectable columns inside the video control sheets:
/// an optional header, a one-shot scroll that reveals the selected row (only as
/// far as needed, so the rows above stay visible), the selected row as where
/// the remote starts, the async selection guard, the scrolling list, and an
/// optional footer.
class SheetSelectionColumn extends StatefulWidget {
  /// Header text, or null to omit the header entirely.
  final String? headerLabel;
  final int itemCount;

  /// Row to scroll into view on first build; ignored when null or <= 0.
  final int? initialIndex;
  final Widget Function(BuildContext context, int index, SheetSelectionColumnScope scope) itemBuilder;
  final List<Widget> footer;

  const SheetSelectionColumn({
    super.key,
    this.headerLabel,
    required this.itemCount,
    required this.initialIndex,
    required this.itemBuilder,
    this.footer = const [],
  });

  @override
  State<SheetSelectionColumn> createState() => _SheetSelectionColumnState();
}

class _SheetSelectionColumnState extends State<SheetSelectionColumn> implements SheetSelectionColumnScope {
  final _initialScroll = InitialItemScrollController();
  final _initialRowFocusNode = FocusNode(debugLabel: 'SheetSelectionInitialRow');
  OverlaySheetController? _sheet;
  bool _offeredInitialFocus = false;
  bool _selectionPending = false;

  /// The row the remote starts on: the selected one, else the first.
  int get _initialRow {
    final index = widget.initialIndex;
    if (index == null || index < 0 || index >= widget.itemCount) return 0;
    return index;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheet = OverlaySheetController.maybeOf(context);
    if (!_offeredInitialFocus && widget.itemCount > 0) {
      _offeredInitialFocus = true;
      _sheet?.offerInitialFocus(_initialRowFocusNode);
    }
  }

  @override
  void dispose() {
    _sheet?.withdrawInitialFocus(_initialRowFocusNode);
    _initialRowFocusNode.dispose();
    _initialScroll.dispose();
    super.dispose();
  }

  @override
  Key? keyFor(int index) => index == 0 ? _initialScroll.firstItemKey : null;

  @override
  FocusNode? focusNodeFor(int index) => index == _initialRow ? _initialRowFocusNode : null;

  @override
  void runExclusive(Future<void> Function() action) => unawaited(_select(action));

  Future<void> _select(Future<void> Function() action) async {
    if (_selectionPending) return;
    setState(() => _selectionPending = true);
    try {
      await action();
      if (mounted) OverlaySheetController.of(context).close();
    } finally {
      if (mounted) setState(() => _selectionPending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _initialScroll.maybeReveal(widget.initialIndex);

    return Column(
      mainAxisSize: .min,
      children: [
        if (widget.headerLabel != null) SheetColumnHeader(label: widget.headerLabel!),
        // Reserve the bar's 2px unconditionally: growing the column mid-tap
        // would nudge a content-sized sheet, and the host eases that as a twitch.
        SizedBox(height: 2, child: _selectionPending ? const LinearProgressIndicator(minHeight: 2) : null),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            controller: _initialScroll.controller,
            itemCount: widget.itemCount,
            itemBuilder: (context, index) => widget.itemBuilder(context, index, this),
          ),
        ),
        ...widget.footer,
      ],
    );
  }
}
