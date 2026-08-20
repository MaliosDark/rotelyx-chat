/// The WebSocket that comes with `dart:io`.
library;

import 'dart:async';
import 'dart:io';

import 'socket_api.dart';

export 'socket_api.dart';

/// Open a socket and complete when it is connected.
///
/// `WebSocket.connect` resolves after the upgrade, so unlike the browser there
/// is no separate open event to wait for.
Future<TextSocket> connectSocket(String url,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final WebSocket socket;
  try {
    socket = await WebSocket.connect(url).timeout(timeout);
  } on TimeoutException {
    throw SocketRefused('$url did not accept a connection');
  } on Object catch (e) {
    throw SocketRefused('cannot reach $url: $e');
  }
  return _IoSocketText(socket);
}

class _IoSocketText implements TextSocket {
  _IoSocketText(this._socket) {
    _socket.listen(
      (dynamic frame) {
        // Text only, for the same reason as the browser implementation: a
        // binary frame from the mailbox would be a defect, not a case to cover.
        if (frame is String) _text.add(frame);
      },
      onError: (Object error) => _closed('the connection failed: $error'),
      onDone: () => _closed('closed (${_socket.closeCode ?? 0})'),
      cancelOnError: false,
    );
  }

  final WebSocket _socket;
  final _text = StreamController<String>.broadcast();
  final _closes = StreamController<String>.broadcast();
  var _done = false;

  /// Set before a close this object asked for, so the notification is not sent.
  ///
  /// `closed` exists to report a socket ending unexpectedly. A close we
  /// requested is not news, and announcing it caused a real failure: retrying a
  /// pairing closes the previous mailbox, and the listener still attached to it
  /// moved the whole service to `failed` while the replacement was mid
  /// handshake. See `rotelyx_service.dart`, `_openMailbox`.
  var _deliberate = false;

  @override
  Stream<String> get messages => _text.stream;

  @override
  Stream<String> get closed => _closes.stream;

  @override
  bool get isOpen => _socket.readyState == WebSocket.open;

  @override
  void send(String text) => _socket.add(text);

  void _closed(String why) {
    if (_done) return;
    _done = true;
    if (_deliberate) return;
    _closes.add(why);
  }

  @override
  Future<void> close() async {
    _deliberate = true;
    await _socket.close();
    _closed('closed by us');
    await _text.close();
    await _closes.close();
  }
}
