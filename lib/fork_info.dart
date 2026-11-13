/// Fork identity — lets you tell this build apart from stock Plezy.
///
/// This file does not exist upstream, so it never conflicts when we rebase onto
/// a new upstream tag. Everything that names the fork lives here.
library;

/// What the fork is, shown on the About screen.
const String kForkName = 'Voice-control fork';

/// The stock Plezy version this build is based on (About and the changelog footer).
const String kForkUpstreamBase = '2.25.0';

/// This build's own version, `x.y.z`, injected at build time via
/// `--dart-define=FORK_VERSION`; empty in local/dev builds. Since 2026-11-05
/// every published version is a full release: x for big things or a move onto
/// a new Plezy, y for a good new feature, z for bug fixes. The build number
/// updates compare stays out of sight, and so does the commit (the log has both).
const String kForkVersion = String.fromEnvironment('FORK_VERSION');

/// True only in a build made as a beta (`--dart-define=FORK_BETA=true`). No
/// published build is one since 2026-11-05; the release tool keeps the option.
const bool kForkBeta = bool.fromEnvironment('FORK_BETA');

/// A fork version as people see it: "2.0.1", or "0.0.2 (beta)" for a build made
/// as a beta ([beta]); the number alone never makes one. Anything that is not
/// `x.y.z` is shown as it is.
String forkVersionLabel(String version, {bool beta = false}) {
  final text = version.trim();
  return beta && RegExp(r'^\d+\.\d+\.\d+$').hasMatch(text) ? '$text (beta)' : text;
}

/// The marker line shown under the version, e.g.
/// "Voice-control fork · based on Plezy 2.23.0".
String forkMarkerLabel() => '$kForkName · based on Plezy $kForkUpstreamBase';

/// The footer for the changelog screen, e.g.
/// "Plezy Fork 2.0.0 · on Plezy 2.25.0" (the version dropped when unknown).
String forkBuildFooter({String version = kForkVersion, bool beta = kForkBeta}) {
  final fork = version.isNotEmpty ? 'Plezy Fork ${forkVersionLabel(version, beta: beta)} · ' : '';
  return '${fork}on Plezy $kForkUpstreamBase';
}
