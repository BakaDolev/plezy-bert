import 'package:flutter/material.dart';
import 'package:plezy/fork_info.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../theme/mono_tokens.dart';
import 'fork_changelog_data.dart';

/// In-app history: what the fork adds, and the stock Plezy it is built on.
/// Fork-local screen (does not exist upstream).
class ForkChangelogScreen extends StatelessWidget {
  const ForkChangelogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = tokens(context).textMuted;
    final children = <Widget>[];

    for (final section in forkChangelog) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 2),
        child: Text(
          section.heading,
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      ));
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(section.subtitle, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
      ));

      for (final entry in section.entries) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Text(entry.date, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
        ));
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 1, 16, 6),
          child: Text(
            entry.title,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ));
        for (final change in entry.changes) {
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 16, 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                Expanded(child: Text(change, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ));
        }
      }
    }

    children.add(const SizedBox(height: 28));
    children.add(Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
      child: Text(forkBuildFooter(), style: theme.textTheme.labelSmall?.copyWith(color: muted)),
    ));

    return FocusedScrollScaffold(
      title: const Text('Changelog'),
      slivers: [SliverList(delegate: SliverChildListDelegate(children))],
    );
  }
}
