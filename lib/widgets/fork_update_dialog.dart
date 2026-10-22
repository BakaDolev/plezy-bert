/// The fork's update dialog, on Windows and Android (fork-only; never upstream).
library;

import 'package:flutter/material.dart';

import '../fork_info.dart';
import '../services/fork_update/update_flow.dart';
import '../utils/dialogs.dart';
import 'dialog_action_button.dart';

/// Shows [flow] until the user leaves it or the system's installer takes over.
/// Leaving mid-download cancels the download.
Future<void> showForkUpdateDialog(BuildContext context, ForkUpdateFlow flow, {required bool isSamsung}) =>
    showScopedDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ForkUpdateDialog(flow: flow, isSamsung: isSamsung),
    );

class ForkUpdateDialog extends StatefulWidget {
  const ForkUpdateDialog({super.key, required this.flow, required this.isSamsung});

  final ForkUpdateFlow flow;
  final bool isSamsung;

  @override
  State<ForkUpdateDialog> createState() => _ForkUpdateDialogState();
}

class _ForkUpdateDialogState extends State<ForkUpdateDialog> {
  ForkUpdateFlow get _flow => widget.flow;

  @override
  void initState() {
    super.initState();
    _flow.addListener(_onFlowChanged);
  }

  @override
  void dispose() {
    _flow.removeListener(_onFlowChanged);
    _flow.cancel();
    super.dispose();
  }

  void _onFlowChanged() {
    if (!mounted) return;
    if (_flow.step == UpdateStep.handedOver) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  void _close() => Navigator.of(context).pop();

  Future<void> _skip() async {
    await _flow.skip();
    if (mounted) _close();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final (Widget content, List<Widget> actions) = switch (_flow.step) {
      UpdateStep.offer || UpdateStep.handedOver => (
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Plezy Fork ${forkVersionLabel(_flow.version)} is ready to install.'),
            if (_flow.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(child: Text(_flow.notes.trim(), style: small)),
              ),
            ],
            if (_flow.offerNote case final note?) ...[const SizedBox(height: 12), Text(note, style: small)],
            if (widget.isSamsung) ...[
              const SizedBox(height: 12),
              Text(
                "If Samsung's Auto Blocker stops the install, turn it off for a moment: "
                'Settings → Security and privacy → Auto Blocker.',
                style: small,
              ),
            ],
          ],
        ),
        [
          DialogActionButton(onPressed: _skip, label: 'Skip this version'),
          DialogActionButton(onPressed: _close, label: 'Later'),
          DialogActionButton(autofocus: true, isPrimary: true, onPressed: _flow.install, label: 'Install'),
        ],
      ),
      UpdateStep.needsPermission => (
        Text(_flow.message ?? ''),
        [
          DialogActionButton(onPressed: _close, label: 'Later'),
          DialogActionButton(onPressed: _flow.install, label: 'Install'),
          DialogActionButton(autofocus: true, isPrimary: true, onPressed: _flow.openSettings, label: 'Open settings'),
        ],
      ),
      UpdateStep.downloading => (
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Downloading… ${(_flow.progress * 100).floor()}%'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _flow.progress),
          ],
        ),
        [DialogActionButton(autofocus: true, onPressed: _flow.cancel, label: 'Cancel')],
      ),
      UpdateStep.checking => (
        const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text('Checking the download…'), SizedBox(height: 12), LinearProgressIndicator()],
        ),
        const <Widget>[],
      ),
      UpdateStep.failed => (
        Text(_flow.message ?? 'The update could not be installed.'),
        [
          DialogActionButton(onPressed: _close, label: 'Close'),
          DialogActionButton(autofocus: true, isPrimary: true, onPressed: _flow.install, label: 'Try again'),
        ],
      ),
    };
    return AlertDialog(title: const Text('Update available'), content: content, actions: actions);
  }
}
