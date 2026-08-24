/// The browser's WebSocket.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'socket_api.dart';

export 'socket_api.dart';

/// Open a socket and complete when the browser reports it open.
Future<TextSocket> connectSocket(String url, {Duration timeout = const Duration(seconds: 15)}) {
  final socket = web.WebSocket(url);
  final open = Completer<TextSocket>();
  final wrapper = _WebSocketText(socket);

  socket.onopen = ((web.Event _) {
    if (!open.isCompleted) open.complete(wrapper);
  }).toJS;

  socket.onerror = ((web.Event _) {
    if (!open.isCompleted) {
      open.completeError(SocketRefused('cannot reach $url'));
    }
    wrapper._closed('the connection failed');
  }).toJS;

  socket.onclose = ((web.CloseEvent event) {
    if (!open.isCompleted) {
      open.completeError(SocketRefused('$url closed the connection'));
    }
    wrapper._closed('closed (${event.code})');
  }).toJS;

  socket.onmessage = ((web.MessageEvent event) {
    // The mailbox only ever sends text. `data` is typed as JSAny? and would be
    // a Blob for a binary frame, so it is read as a JSString rather than
    // stringified: `toString()` on a Blob yields "[object Blob]", which parses
    // as nothing and looks exactly like a malformed server.
    // The same hazard the native side has: a frame can arrive after `close`
    // has shut the controller, and adding to a closed one throws where nothing
    // can catch it. A browser delivers the event even when nobody is listening
    // any more.
    if (wrapper._done || wrapper._text.isClosed) return;

    final raw = event.data;
    if (raw == null || !raw.isA<JSString>()) return;
    wrapper._text.add((raw as JSString).toDart);
  }).toJS;

  return open.future.timeout(timeout,
      onTimeout: () => throw SocketRefused('$url did not accept a connection'));
}

class _WebSocketText implements TextSocket {
  _WebSocketText(this._socket);

  final web.WebSocket _socket;
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

  /// `WebSocket.readyState` values, written out rather than taken from the
  /// binding: the generated constants have moved between `package:web`
  /// releases, and a wrong comparison here fails silently as "nothing sends".
  @override
  bool get isOpen => _socket.readyState == 1;

  @override
  void send(String text) => _socket.send(text.toJS);

  void _closed(String why) {
    if (_done) return;
    _done = true;
    if (_deliberate) return;
    _closes.add(why);
  }

  @override
  Future<void> close() async {
    _deliberate = true;
    _socket.close();
    _closed('closed by us');
    await _text.close();
    await _closes.close();
  }
}
