/// A fingerprint instead of typing the PIN.
///
/// # What this is, said before anything uses it
///
/// A **shortcut to the PIN, not a replacement for it.** The PIN is what the
/// lock is made of: it is stretched, rate limited, and it is what a locked
/// conversation is sealed under. This only decides whether somebody has to type
/// it this time.
///
/// Nothing is stored to make it work. A successful prompt marks the session as
/// unlocked in memory, exactly as entering the PIN does, and a restart asks
/// again. If it were a replacement, the secret would have to live in the
/// Keystore rather than in somebody's head, and then an unlocked phone would be
/// a phone that opens everything.
library;

import 'os.dart' as os;

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('rotelyx/biometrics');

/// Whether this device has a fingerprint or face enrolled and usable.
///
/// False everywhere except Android for now, and false on an Android with none
/// enrolled. Checked before the switch is drawn, because a switch that turns
/// itself off after being pressed is worse than one that was never there.
Future<bool> biometricsAvailable() async {
  if (!os.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('available') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Ask. False when it was cancelled, refused, or the device has none.
///
/// False is not an error and does not need a message: it means "type the PIN",
/// which is a working path and the one the prompt itself offers.
Future<bool> askBiometric() async {
  if (!os.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('prompt') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
