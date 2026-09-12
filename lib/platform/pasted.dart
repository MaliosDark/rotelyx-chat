/// A picture on the clipboard, which is how a sticker reaches an iPhone
/// application.
library;

export 'pasted_native.dart' if (dart.library.js_interop) 'pasted_web.dart';
