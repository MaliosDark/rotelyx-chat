/// The transport, as far as a browser is concerned: absent.
///
/// A browser cannot open a QUIC endpoint of its own. It has no UDP socket to
/// bind and no way to be connected to, so there is nothing here to implement
/// and these types exist only so the shared call code compiles.
///
/// They are not a stub in the sense of pretending. Every one of them refuses,
/// and `openEndpoint` in `web.dart` returns null before any of this is reached,
/// so the interface says the call cannot be placed rather than failing part way
/// through one.
///
/// When browser calls arrive they will not arrive here. A browser will reach
/// the relay over WebSocket or WebTransport, which is a different transport
/// with different framing, and it will get its own file.
library;

import 'dart:typed_data';

/// The transport said no, with a reason.
///
/// Mirrors the native class so `on NetRefused` in shared code catches on both.
class NetRefused implements Exception {
  const NetRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A bound endpoint, which on the web is never bound.
class RotelyxEndpoint {
  RotelyxEndpoint._();

  static const _reason = 'a browser cannot bind a transport endpoint';

  static RotelyxEndpoint open(
    Object lib, {
    required String identityHex,
    required String relay,
  }) =>
      throw const NetRefused(_reason);

  String? get address => null;

  int get handle => -1;

  RotelyxConnection connect(String peerAddress) =>
      throw const NetRefused(_reason);

  RotelyxConnection? accept({
    Duration timeout = const Duration(milliseconds: 250),
  }) =>
      null;

  void close() {}
}

/// A live connection to one peer, which on the web is never live.
class RotelyxConnection {
  RotelyxConnection._();

  bool send(Uint8List datagram) => false;

  Uint8List? receive({Duration timeout = const Duration(milliseconds: 20)}) =>
      null;

  void close() {}
}
