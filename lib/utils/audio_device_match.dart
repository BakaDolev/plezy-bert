import '../mpv/mpv.dart';
import 'app_logger.dart';

/// The device in [devices] a controller means by [query], or null.
///
/// Deliberately a plain case-insensitive substring test, unlike the language
/// matcher: output devices carry free-text OS names ("LG TV (NVIDIA High
/// Definition Audio)") with no codes or aliases to reconcile, so a person says
/// a fragment of what they see. [AudioDevice.description] is checked first
/// because it is the human-readable half; the raw name still matches so an
/// exact device id always works.
AudioDevice? matchAudioDevice(String query, List<AudioDevice> devices) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return null;
  for (final device in devices) {
    if (device.description.toLowerCase().contains(normalized)) return device;
    if (device.name.toLowerCase().contains(normalized)) return device;
  }
  return null;
}

/// Moves [player] onto a controller's chosen [device], then passes its name to
/// [remember] so later videos open on it, as a pick in the player's own menu
/// does. A device the core refuses is logged and not remembered.
Future<void> applyRemoteAudioDevice(
  Player player,
  AudioDevice device,
  Future<void> Function(String name) remember,
) async {
  try {
    await player.setAudioDevice(device);
    await remember(device.name);
  } catch (error, stackTrace) {
    appLogger.w('Companion remote: audio output not applied', error: error, stackTrace: stackTrace);
  }
}
