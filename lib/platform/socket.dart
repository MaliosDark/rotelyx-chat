/// A text WebSocket, on whichever platform this is.
///
/// The browser has `WebSocket` through `package:web`; everything else has
/// `dart:io`'s. They are the same protocol and different types, which is the
/// whole reason this file exists.
///
/// Only what the mailbox needs: connect, send text, receive text, close. No
/// binary frames, because the mailbox speaks JSON and a binary frame from it
/// would be a bug rather than a feature to support.
library;

export 'socket_native.dart' if (dart.library.js_interop) 'socket_web.dart';
