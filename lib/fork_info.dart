/// Fork identity — lets you tell this build apart from stock Plezy.
///
/// This file does not exist upstream, so it never conflicts when we rebase onto
/// a new upstream tag. Everything that names the fork lives here; bump
/// [kForkUpdated] (and add a changelog entry) each time a fork build ships.
library;

/// What the fork is, shown on the About screen.
const String kForkName = 'Voice-control fork';

/// Date this fork build shipped, ISO `YYYY-MM-DD`. Shown as e.g. "Aug 20, 2026".
const String kForkUpdated = '2026-10-13';

/// The stock Plezy version this build is based on (for the changelog footer).
const String kForkUpstreamBase = '2.23.0';

/// Short git commit, injected at build time via `--dart-define=GIT_COMMIT`.
/// Empty in local/dev builds; shown only in the changelog footer, for support.
const String kForkGitCommit = String.fromEnvironment('GIT_COMMIT');

const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Format an ISO `YYYY-MM-DD` as "Aug 20, 2026". Returns the input unchanged if
/// it is not a well-formed ISO date (so a bad constant degrades gracefully).
String formatForkDate(String iso) {
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null || m < 1 || m > 12) return iso;
  return '${_months[m - 1]} $d, $y';
}

/// The marker line shown under the real version, e.g.
/// "Voice-control fork · updated Aug 20, 2026".
String forkMarkerLabel() => '$kForkName · updated ${formatForkDate(kForkUpdated)}';

/// The build-id footer for the changelog screen, e.g.
/// "Build a1b2c3d · on Plezy 2.21.0" (commit dropped when unknown).
String forkBuildFooter() {
  final short = kForkGitCommit.length >= 7 ? kForkGitCommit.substring(0, 7) : kForkGitCommit;
  final build = short.isNotEmpty ? 'Build $short · ' : '';
  return '${build}on Plezy $kForkUpstreamBase';
}
