/// Which transport this build gets, decided at compile time.
///
/// The same trick as `backend.dart`, and for the same reason: `net_native.dart`
/// imports `dart:ffi`, which a web build cannot have. Importing it directly
/// from shared code is what broke `flutter build web` when calls landed, since
/// the compiler follows the import before it ever reaches a platform check.
///
/// Native resolves this to exactly the file it used before, so nothing about a
/// call on a phone or a desktop changes.
library;

export 'net_native.dart' if (dart.library.js_interop) 'net_web.dart';
