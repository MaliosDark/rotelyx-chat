/// The push token source for whichever platform this was compiled for.
library;

export 'apple_push_native.dart'
    if (dart.library.js_interop) 'apple_push_web.dart';
