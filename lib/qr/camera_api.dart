/// The vocabulary a camera failure needs, shared by both platforms.
///
/// Split out so `camera_native.dart` can report a refusal without importing
/// anything from the browser, and so the scanner screen can switch on the same
/// enum whichever platform it is running on.
library;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Why the camera could not be opened, in terms a user can act on.
enum CameraProblem {
  /// The user said no, or said no once before and the platform remembers.
  refused,

  /// The device has no camera, or another application holds it.
  missing,

  /// The page is not on `https` or `localhost`, so the browser will not hand
  /// over a camera at all. This is not something the app can work around.
  insecure,

  /// Anything else the browser reported.
  unknown,

  /// This platform has a camera and this application cannot reach it yet.
  /// Not a fault of the device, the user or the page: work that is not done.
  unbuilt,
}

class CameraDenied implements Exception {
  const CameraDenied(this.problem, this.detail);
  final CameraProblem problem;
  final String detail;

  String get message => switch (problem) {
        CameraProblem.refused => kIsWeb
            ? 'The browser is not allowing the camera. Open the padlock beside '
                'the address and set camera access to allow, then try again.'
            : 'Rotelyx has not been given the camera. Grant it in the system '
                'settings for Rotelyx, under permissions, then try again.',
        CameraProblem.missing =>
          'No camera is available. Another program may be holding it.',
        CameraProblem.insecure =>
          'Browsers only give a camera to a page served over https, or over '
              'localhost. This page is on neither.',
        CameraProblem.unknown => 'The camera could not be opened: $detail',
        CameraProblem.unbuilt =>
          'Scanning is not built for this platform yet. Type the code below '
              'instead, or read it aloud: it works just as well.',
      };

  @override
  String toString() => message;
}

