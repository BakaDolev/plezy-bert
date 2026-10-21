import 'package:flutter/services.dart';

import 'device_channel.dart';

/// Whether the system screensaver (an Android dream) is showing.
///
/// Android reports a dream to the app only as a lifecycle stop — the same as
/// leaving for another app — so the native side follows the dream broadcasts.
/// False whenever it cannot tell (no native handler, other platforms).
Future<bool> isScreensaverShowing() async {
  try {
    return await deviceChannel.invokeMethod<bool>('isScreensaverShowing') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
