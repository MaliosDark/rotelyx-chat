/// The few things the surrounding page does, which a phone does not have.
///
/// Three of them, all trivial, all previously written straight into widgets
/// with `dart:js_interop` imports. That is what made `lib/ui/` web-only along
/// with everything else.
library;

export 'host_native.dart' if (dart.library.js_interop) 'host_web.dart';
