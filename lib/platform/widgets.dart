/// Home and lock screen widgets, where the platform has them.
///
/// Native first and web behind the guard, the way the rest of this folder
/// splits. A browser has no home screen to put anything on.
library;

export 'widgets_native.dart' if (dart.library.js_interop) 'widgets_web.dart';
