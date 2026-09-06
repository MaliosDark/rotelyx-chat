/// The watch, or nothing where there is none.
///
/// Conditional like the rest of `lib/platform/`: a web build must not carry a
/// `dart:io` import, and nothing above here needs to know which it got. Native
/// first and the browser behind `js_interop`, which is the shape
/// `test/web_build_test.dart` walks to decide what is allowed to reach for
/// `dart:io`.
library;

export 'watch_native.dart' if (dart.library.js_interop) 'watch_web.dart';
