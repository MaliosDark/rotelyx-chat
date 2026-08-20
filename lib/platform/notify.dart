/// The notifier for whichever platform this was compiled for.
library;

export 'notify_native.dart' if (dart.library.js_interop) 'notify_web.dart';
