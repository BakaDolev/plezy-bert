/// Whether video playback should keep going (audio-only) after the app is
/// backgrounded or the screen is turned off.
///
/// This deliberately overrides the handheld branch of
/// [shouldPauseVideoForBackground], which pauses a phone's video on background.
/// The override is scoped tightly:
///
/// - **Phone only** (`isHandheld`): Android TV keeps its suspend-and-release
///   policy (`shouldSuspendPlayerForTvBackground`) and Android Automotive keeps
///   pausing — the latter is a driver-distraction safety gate that must never be
///   defeated by a user setting.
/// - **VOD only** (`!isLive`): a live session's tuner/transcode state must stay
///   intact across backgrounding.
/// - **Opt-out** (`settingEnabled`): gated behind the `background_playback`
///   preference.
bool shouldPlayVideoInBackground({
  required bool isAndroid,
  required bool isHandheld,
  required bool isTv,
  required bool isAutomotive,
  required bool isLive,
  required bool settingEnabled,
}) => isAndroid && isHandheld && !isTv && !isAutomotive && !isLive && settingEnabled;

/// Whether screen-off listening puts someone in front of the Up Next prompt.
///
/// Upstream holds the prompt's countdown while a phone is backgrounded: nobody
/// is there to answer it, and advancing would start the next episode behind
/// the viewer's back. With background audio armed and the viewer still meaning
/// to play, the listener is there and overnight listening needs the next
/// episode to start on its own. A pause (lock screen, headset) clears the
/// intent, and the hold comes back.
bool screenOffListenerPresent({required bool backgroundAudioArmed, required bool intentToPlay}) =>
    backgroundAudioArmed && intentToPlay;
