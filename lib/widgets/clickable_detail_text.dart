import 'package:flutter/material.dart';
import '../focus/input_mode_tracker.dart';
import '../i18n/strings.g.dart';

/// Text widget that shows hover underline + pointer cursor only in pointer mode.
/// Keyboard/dpad mode keeps plain visual text while screen readers retain the
/// separately invokable detail action.
class ClickableDetailText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final VoidCallback onTap;
  final int maxLines;

  const ClickableDetailText({super.key, required this.text, this.style, required this.onTap, this.maxLines = 1});

  @override
  State<ClickableDetailText> createState() => _ClickableDetailTextState();
}

class _ClickableDetailTextState extends State<ClickableDetailText> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isKeyboard = InputModeTracker.isKeyboardMode(context);
    final baseStyle = widget.style ?? const TextStyle();
    final text = Semantics(
      label: widget.text,
      hint: t.mediaMenu.viewDetails,
      button: true,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Text(
        widget.text,
        maxLines: widget.maxLines,
        overflow: .ellipsis,
        style: isKeyboard
            ? baseStyle
            : baseStyle.copyWith(
                decoration: _isHovered ? TextDecoration.underline : null,
                decorationColor: baseStyle.color,
              ),
      ),
    );

    if (isKeyboard) return text;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(excludeFromSemantics: true, onTap: widget.onTap, child: text),
    );
  }
}
