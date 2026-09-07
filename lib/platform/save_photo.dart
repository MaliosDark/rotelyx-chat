/// Keeping a copy of a picture.
///
/// A phone puts it in the photo library; a browser downloads it. Both are what
/// somebody means by save on the platform they are on, and neither is what the
/// other means.
library;

export 'save_photo_native.dart' if (dart.library.js_interop) 'save_photo_web.dart';
