/// Fork identity — lets you tell this build apart from stock Plezy.
///
/// This file does not exist upstream, so it never conflicts when we rebase onto
/// a new upstream tag. Everything that names the fork lives here.
library;

/// What the fork is, shown on the About screen.
const String kForkName = 'Voice-control fork';

/// The stock Plezy version this build is based on (About and the changelog footer).
const String kForkUpstreamBase = '2.23.0';

/// This build's own version, `x.y.z`, injected at build time via
/// `--dart-define=FORK_VERSION`; empty in local/dev builds. Every beta bumps z;
/// a release bumps y (or x for a big change) and starts z again at 0. The
/// build number updates compare stays out of sight, and so does the commit
/// (the log has both).
const String kForkVersion = String.fromEnvironment('FORK_VERSION');

/// A fork version as people see it: "0.0.2 (beta)" (a last number above 0 is
/// a beta) or "1.1.0" (a release). Anything that is not `x.y.z` is shown as it is.
String forkVersionLabel(String version) {
  final text = version.trim();
  final match = RegExp(r'^\d+\.\d+\.(\d+)$').firstMatch(text);
  if (match == null) return text;
  return int.parse(match.group(1)!) > 0 ? '$text (beta)' : text;
}

/// The marker line shown under the version, e.g.
/// "Voice-control fork · based on Plezy 2.23.0".
String forkMarkerLabel() => '$kForkName · based on Plezy $kForkUpstreamBase';

/// The footer for the changelog screen, e.g.
/// "Plezy Fork 0.0.2 (beta) · on Plezy 2.23.0" (the version dropped when unknown).
String forkBuildFooter({String version = kForkVersion}) {
  final fork = version.isNotEmpty ? 'Plezy Fork ${forkVersionLabel(version)} · ' : '';
  return '${fork}on Plezy $kForkUpstreamBase';
}
