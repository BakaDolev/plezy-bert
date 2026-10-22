/// About screen: check for updates now, and the beta switch (fork-only; never upstream).
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../fork_info.dart';
import '../../services/fork_update/fork_updater.dart';
import '../../services/fork_update/playback_probe.dart';
import '../../services/settings_service.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';

/// "0.0.2 (beta)": the fork's own version ([kForkVersion]), or "dev build" for
/// a local build without one. The build number updates compare and the commit
/// stay in the log.
String forkVersionText({String version = kForkVersion}) => version.isEmpty ? 'dev build' : forkVersionLabel(version);

/// What the About button says when no update dialog opens.
@visibleForTesting
String? forkUpdateMessage(ForkUpdateOutcome outcome) => switch (outcome) {
  ForkUpdateOutcome.shown => null,
  ForkUpdateOutcome.upToDate => "You're up to date",
  ForkUpdateOutcome.noRelease => 'Nothing released on this channel yet',
  ForkUpdateOutcome.failed => "Couldn't check for updates",
  ForkUpdateOutcome.playing => 'Stop playback to update',
  ForkUpdateOutcome.unavailable => "This copy of Plezy doesn't update itself",
  // Only automatic checks stop there; the button itself always checks.
  ForkUpdateOutcome.checksOff => 'Automatic update checks are off on this computer',
};

class ForkUpdateTiles extends StatefulWidget {
  const ForkUpdateTiles({super.key, this.check});

  /// Replaces [ForkUpdater.check] in tests.
  final Future<ForkUpdateOutcome> Function()? check;

  @override
  State<ForkUpdateTiles> createState() => _ForkUpdateTilesState();
}

class _ForkUpdateTilesState extends State<ForkUpdateTiles> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final outcome =
        await (widget.check?.call() ??
            ForkUpdater.instance.check(
              manual: true,
              isPlaybackActive: () => !mounted || isPlaybackActiveIn(context),
              dialogContext: () => mounted ? context : null,
            ));
    if (!mounted) return;
    setState(() => _checking = false);
    final message = forkUpdateMessage(outcome);
    if (message != null) showAppSnackBar(context, message);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: SettingsService.instance.listenable(forkUpdateBetaPref),
          builder: (context, beta, _) => FocusableListTile(
            leading: const AppIcon(Symbols.system_update_rounded, fill: 1),
            title: const Text('Check for updates'),
            subtitle: Text(_checking ? 'Checking…' : (beta ? 'Beta builds' : 'Stable builds')),
            onTap: _check,
          ),
        ),
        const SettingSwitchTile(
          pref: forkUpdateBetaPref,
          icon: Symbols.science_rounded,
          title: 'Beta updates',
          subtitle: 'Get new builds before everyday devices',
        ),
      ],
    );
  }
}
