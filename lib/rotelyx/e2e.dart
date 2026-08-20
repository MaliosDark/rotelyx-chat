/// The test hook, where there is a JavaScript to publish it to.
///
/// `tool/e2e/drive-dart.py` reaches the real service through
/// `window.__rotelyx`. There is no window on a phone, and a driver would reach
/// a native build a different way entirely, so the native side is empty.
///
/// Both are compiled out unless `--dart-define=e2e=true` is passed. The web
/// implementation explains why that guard is the only thing standing between a
/// test hook and a remote control for somebody else's conversations.
library;

export 'e2e_native.dart' if (dart.library.js_interop) 'e2e_web.dart';
