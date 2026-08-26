/// Hand text to whatever the person already uses to talk to people.
///
/// Wired up on Android. Everywhere else this returns false and the caller falls
/// back to the clipboard, which is why it returns a bool rather than throwing:
/// there is nothing here a person could act on, and a failure notice for a
/// share sheet that does not exist on this platform is noise.
library;

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('rotelyx/share');

/// True when the system took it. False when there is no share sheet here.
Future<bool> shareText(String text, {String? title, String? subject}) async {
  try {
    return await _channel.invokeMethod<bool>('text', {
          'text': text,
          if (title != null) 'title': title,
          if (subject != null) 'subject': subject,
        }) ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    // The platform has no implementation registered, which is every platform
    // but Android today.
    return false;
  }
}
