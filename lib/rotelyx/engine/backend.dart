/// Picks the engine for the platform being compiled for.
///
/// `dart.library.js_interop` exists only in a browser build, so the condition
/// is a compile-time fact rather than a runtime check: whichever file is not
/// chosen is not compiled, which is the point. `native.dart` imports
/// `dart:ffi`, which a web build cannot have, and `web.dart` imports
/// `dart:js_interop`, which an Android build cannot have.
///
/// This one line is the whole reason the application can target both.
library;

export 'native.dart' if (dart.library.js_interop) 'web.dart';
