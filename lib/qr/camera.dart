/// Opening a camera to look for a QR code.
///
/// The browser has `getUserMedia` and a canvas, which is all the decoder in
/// `lib/qr/` needs. A phone has a camera too, but reaching it from Dart means a
/// platform channel, and the frames have to arrive as a byte buffer rather than
/// as a video element for the same decoder to read them.
///
/// That work is real and is not done. The scanner screen has always had a typed
/// fallback beside the viewfinder for exactly this class of reason, so on a
/// phone the code can still be entered while the camera cannot yet be opened.
library;

export 'camera_native.dart' if (dart.library.js_interop) 'camera_web.dart';
