/// Fetching a file somebody linked to. See `fetch_api.dart` for the argument.
library;

export 'fetch_native.dart' if (dart.library.js_interop) 'fetch_web.dart';
