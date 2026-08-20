/// Choosing a file to attach.
///
/// The browser can do this with an `<input type=file>` and nothing else. A
/// phone cannot: it needs a document picker, which on Android is an intent and
/// on iOS a view controller, and reaching either from Dart means a plugin.
///
/// So the native side is honestly unimplemented rather than quietly broken. It
/// returns null and the caller says so, which is what an application should do
/// about a feature it does not have on the platform it is running on.
library;

export 'file_pick_native.dart' if (dart.library.js_interop) 'file_pick_web.dart';
