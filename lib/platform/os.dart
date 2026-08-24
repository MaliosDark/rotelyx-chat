/// Which platform this build is for, answerable on every platform.
///
/// # Why this exists
///
/// `dart:io` is not available in a browser, and reading `Platform.isAndroid`
/// there does not return false: it throws `Unsupported operation:
/// Platform._operatingSystem`, at the moment the widget asking is built.
///
/// Everything else in this folder already splits at compile time, so the
/// unavailable half is never compiled. Two files were reaching for `dart:io`
/// directly instead, and both were reachable from the web build:
/// `call_audio.dart` through the chat screen's call button, and
/// `biometrics.dart` through settings and the PIN screen. Both crashed the
/// screen that asked.
///
/// One question, asked in one place, rather than a conditional pair per file
/// that needs it.
library;

export 'os_native.dart' if (dart.library.js_interop) 'os_web.dart';
