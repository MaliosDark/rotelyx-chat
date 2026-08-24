/// Opening a camera to look for a QR code.
///
/// The browser has `getUserMedia` and a canvas, which is all the decoder in
/// `lib/qr/` needs. A phone has a camera too, but reaching it from Dart means a
/// platform channel, and the frames have to arrive as a byte buffer rather than
/// as a video element for the same decoder to read them.
///
/// That work is done: `camera_native.dart` drives CameraX through a platform
/// channel and hands the same decoder a luma plane. The scanner screen still
/// keeps a typed fallback beside the viewfinder, because a camera can always be
/// refused, held by another application, or too dark to read a code in.
library;

export 'camera_native.dart' if (dart.library.js_interop) 'camera_web.dart';
