/// The browser.
library;

import 'dart:js_interop';

import 'package:flutter_web_plugins/url_strategy.dart' as url;

@JS('rotelyxAppReady')
external JSFunction? get _appReady;

/// Routes become real paths rather than fragments.
void useCleanUrls() => url.usePathUrlStrategy();

/// Tell the boot screen in `web/index.html` that the application is ready.
///
/// Absent when the page was not served by our own `index.html`, which is the
/// case under `flutter test` and in a driven integration test, so the call is
/// conditional rather than assumed.
void appReady() => _appReady?.callAsFunction();
