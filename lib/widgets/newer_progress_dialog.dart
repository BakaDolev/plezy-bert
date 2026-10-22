import 'package:flutter/material.dart';

import '../utils/dialogs.dart';
import '../utils/formatters.dart';
import 'dialog_action_button.dart';

/// Another device watched further while this one was paused: true continues
/// from [newer], false stays at [own], null (dismissed) decides nothing.
Future<bool?> showNewerProgressDialog(BuildContext context, {required Duration newer, required Duration own}) {
  final there = formatDurationTimestamp(newer);
  final here = formatDurationTimestamp(own);
  return showScopedDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Watched on another device'),
      content: Text('You watched further on another device. Continue from $there, or stay at $here?'),
      actions: [
        DialogActionButton(onPressed: () => Navigator.pop(dialogContext, false), label: 'Stay at $here'),
        DialogActionButton(
          autofocus: true,
          isPrimary: true,
          onPressed: () => Navigator.pop(dialogContext, true),
          label: 'Continue from $there',
        ),
      ],
    ),
  );
}
