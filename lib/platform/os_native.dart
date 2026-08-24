/// Platform detection where `dart:io` exists.
library;

import 'dart:io' show Platform;

bool get isAndroid => Platform.isAndroid;
bool get isIOS => Platform.isIOS;

/// A phone or a tablet, which is where the native channels are wired up.
bool get isMobile => Platform.isAndroid || Platform.isIOS;
