/// The QUIC connection a call runs on.
///
/// # Why this is separate from everything else in `engine/`
///
/// Because everything else in `engine/` is offline. `session.send` hands back
/// ciphertext for this application to move, and it moves it over the mailbox.
/// Twenty operations and not one opens a socket, which is what lets the phone
/// carry bytes however it can.
///
/// This is the exception, and it is the only one. Voice needs datagrams and
/// needs to cross NAT, and neither survives the mailbox: that is a WebSocket,
/// which is TCP, and one lost segment stalls everything queued behind it. On a
/// call a frame that arrives late is worse than one that never arrives.
///
/// # Relay only, and there is no switch
///
/// The library refuses a direct path on a call, because a direct path shows the
/// other person this device's address. `rotelyx_net_open` fixes the policy
/// rather than accepting one, so there is nothing to get wrong here either.
///
/// # What the address is, and what it is not
///
/// [RotelyxEndpoint.address] is already filtered on the far side: the IPs are
/// stripped and the relay is put in their place. It is safe to send to whoever
/// is being called. Sending the unfiltered one would be handing them a
/// location, which is the mistake this whole path is arranged to avoid.
library;

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef OpenNative = Int64 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef OpenDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

typedef AddrNative = Int32 Function(Int64, Pointer<Pointer<Utf8>>);
typedef AddrDart = int Function(int, Pointer<Pointer<Utf8>>);

typedef ConnectNative = Int64 Function(Int64, Pointer<Utf8>);
typedef ConnectDart = int Function(int, Pointer<Utf8>);

typedef AcceptNative = Int64 Function(Int64, Int32);
typedef AcceptDart = int Function(int, int);

typedef SendNative = Int32 Function(Int64, Pointer<Uint8>, Int32);
typedef SendDart = int Function(int, Pointer<Uint8>, int);

typedef RecvNative = Int32 Function(Int64, Pointer<Uint8>, Int32, Int32);
typedef RecvDart = int Function(int, Pointer<Uint8>, int, int);

typedef CloseNative = Int32 Function(Int64);
typedef CloseDart = int Function(int);

typedef FreeNative = Void Function(Pointer<Utf8>);
typedef FreeDart = void Function(Pointer<Utf8>);

typedef LastErrorNative = Int32 Function(Pointer<Pointer<Utf8>>);
typedef LastErrorDart = int Function(Pointer<Pointer<Utf8>>);

/// The eight transport symbols, looked up once.
class NetSymbols {
  NetSymbols(DynamicLibrary handle)
      : open = handle.lookupFunction<OpenNative, OpenDart>('rotelyx_net_open'),
        addr = handle.lookupFunction<AddrNative, AddrDart>('rotelyx_net_addr'),
        connect =
            handle.lookupFunction<ConnectNative, ConnectDart>('rotelyx_net_connect'),
        accept =
            handle.lookupFunction<AcceptNative, AcceptDart>('rotelyx_net_accept'),
        send = handle.lookupFunction<SendNative, SendDart>('rotelyx_net_send'),
        recv = handle.lookupFunction<RecvNative, RecvDart>('rotelyx_net_recv'),
        closeConnection =
            handle.lookupFunction<CloseNative, CloseDart>('rotelyx_net_close'),
        shutdown =
            handle.lookupFunction<CloseNative, CloseDart>('rotelyx_net_shutdown'),
        free = handle.lookupFunction<FreeNative, FreeDart>('rotelyx_string_free') {
    // Looked up on its own and allowed to be absent.
    //
    // Every symbol above is in the initialiser list, so one of them missing
    // throws and the whole transport is reported as "not built". That is right
    // for the eight the transport needs and wrong for this one, which only
    // explains a failure: a library from before it existed would otherwise
    // stop calls working entirely in order to be unable to say why.
    try {
      _lastError = handle
          .lookupFunction<LastErrorNative, LastErrorDart>('rotelyx_net_last_error');
    } on ArgumentError {
      _lastError = null;
    }
  }

  LastErrorDart? _lastError;

  /// Why the last `open` would not bind, when the library can say.
  String? lastError() {
    final fn = _lastError;
    if (fn == null) return null;
    final out = calloc<Pointer<Utf8>>();
    try {
      if (fn(out) != 0) return null;
      final text = out.value.toDartString();
      free(out.value);
      return text;
    } on Object {
      return null;
    } finally {
      calloc.free(out);
    }
  }

  final OpenDart open;
  final AddrDart addr;
  final ConnectDart connect;
  final AcceptDart accept;
  final SendDart send;
  final RecvDart recv;
  final CloseDart closeConnection;
  final CloseDart shutdown;
  final FreeDart free;
}

/// Why an endpoint would not open.
String endpointFailure(int code) => switch (code) {
      -1 => 'the identity or relay could not be read',
      -2 => 'the identity is not thirty two bytes',
      -3 => 'that relay address will not parse',
      -4 => 'the endpoint would not bind to the network',
      _ => 'the endpoint could not be opened ($code)',
    };

/// A bound endpoint. One per device, not one per call.
class RotelyxEndpoint {
  RotelyxEndpoint._(this._lib, this._handle);

  final NetSymbols _lib;
  final int _handle;
  bool _closed = false;

  /// Bind, with the identity this device keeps and the relay to be reached
  /// through.
  ///
  /// [identityHex] is thirty two bytes as hex, and it is this device's
  /// long-term name on the transport. The same bytes on two devices is one
  /// identity in two places, which nothing here stops and nobody enjoys
  /// debugging.
  static RotelyxEndpoint open(
    NetSymbols lib, {
    required String identityHex,
    required String relay,
  }) {
    final identity = identityHex.toNativeUtf8();
    final url = relay.toNativeUtf8();
    try {
      final handle = lib.open(identity, url);
      if (handle < 0) {
        final why = lib.lastError();
        throw NetRefused(
            why == null ? endpointFailure(handle) : '${endpointFailure(handle)}: $why');
      }
      return RotelyxEndpoint._(lib, handle);
    } finally {
      calloc.free(identity);
      calloc.free(url);
    }
  }

  /// This device's address, to send to whoever is being called.
  ///
  /// Already filtered on the far side: no IP addresses, just the relay. Safe
  /// to put in a message.
  String? get address {
    if (_closed) return null;

    final out = calloc<Pointer<Utf8>>();
    try {
      if (_lib.addr(_handle, out) != 0) return null;
      final reply = out.value;
      if (reply == nullptr) return null;
      try {
        return reply.toDartString();
      } finally {
        _lib.free(reply);
      }
    } finally {
      calloc.free(out);
    }
  }

  /// Connect to a peer's address. Blocks until it is up or fails.
  RotelyxConnection connect(String peerAddress) {
    final addr = peerAddress.toNativeUtf8();
    try {
      final handle = _lib.connect(_handle, addr);
      if (handle < 0) {
        throw NetRefused(handle == -3
            ? 'that address will not decode'
            : 'the connection failed');
      }
      return RotelyxConnection._(_lib, handle);
    } finally {
      calloc.free(addr);
    }
  }

  /// Wait up to [timeout] for a peer to connect.
  ///
  /// Null when nobody came, which is the ordinary answer and not a failure:
  /// the caller asks again.
  ///
  /// It takes a timeout rather than simply blocking because a Dart isolate has
  /// one thread. A blocking accept there does not wait alongside other work, it
  /// stops the isolate, so a connect that was meant to happen concurrently
  /// never runs and both sides wait for each other. That was the first shape of
  /// this and it deadlocked a test for ten minutes before anyone noticed.
  RotelyxConnection? accept({
    Duration timeout = const Duration(milliseconds: 250),
  }) {
    final handle = _lib.accept(_handle, timeout.inMilliseconds);
    if (handle == 0) return null;
    if (handle < 0) throw const NetRefused('a connection arrived and failed');
    return RotelyxConnection._(_lib, handle);
  }

  /// The number the native registry knows this endpoint by.
  ///
  /// Exposed so [acceptOnEndpoint] can be handed it across an isolate.
  int get handle => _handle;

  void close() {
    if (_closed) return;
    _closed = true;
    _lib.shutdown(_handle);
  }
}

/// A live connection to one peer.
class RotelyxConnection {
  RotelyxConnection._(this._lib, this._handle)
      : _buffer = calloc<Uint8>(_maxDatagram);

  /// The largest datagram this will carry, matching the codec's own ceiling.
  static const int _maxDatagram = 1200;

  final NetSymbols _lib;
  final int _handle;

  /// Allocated once and reused, because this is on the audio path and a malloc
  /// per frame is how a working call becomes an intermittent one.
  final Pointer<Uint8> _buffer;

  bool _closed = false;

  /// Send one. Does not block: a QUIC datagram is fire and forget, which is
  /// what makes it right for voice.
  bool send(Uint8List datagram) {
    if (_closed || datagram.isEmpty || datagram.length > _maxDatagram) {
      return false;
    }
    _buffer.asTypedList(datagram.length).setAll(0, datagram);
    return _lib.send(_handle, _buffer, datagram.length) == 0;
  }

  /// Read one, waiting up to [timeout] for it.
  ///
  /// Null when nothing arrived in time, which is the ordinary case between
  /// frames and not a failure. A timeout rather than a blocking read so the
  /// audio loop keeps its own clock and can be stopped when the call ends.
  Uint8List? receive({Duration timeout = const Duration(milliseconds: 20)}) {
    if (_closed) return null;

    final length =
        _lib.recv(_handle, _buffer, _maxDatagram, timeout.inMilliseconds);
    if (length <= 0) return null;

    return Uint8List.fromList(_buffer.asTypedList(length));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _lib.closeConnection(_handle);
    calloc.free(_buffer);
  }
}

/// The transport said no, with a reason.
class NetRefused implements Exception {
  const NetRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Wait for a peer on an endpoint handle, from anywhere.
///
/// # Why a raw handle rather than the object
///
/// So it can be called from another isolate. The registry that owns endpoints
/// and connections lives in the native library, which is loaded once per
/// process, so a handle is meaningful in every isolate that opens the library
/// rather than only in the one that created it.
///
/// That matters because accepting is the one operation a caller genuinely
/// wants off its own thread. Polling it from a timer works and is what a phone
/// does between frames of interface; waiting on it properly, without a
/// timer, means an isolate, and an isolate can only be handed numbers.
///
/// Returns the connection handle, 0 if nobody came, negative on failure.
int acceptOnEndpoint(int endpointHandle, {int timeoutMs = 15000}) {
  final symbols = loadNetSymbols();
  if (symbols == null) return -2;
  return symbols.accept(endpointHandle, timeoutMs);
}

/// Open the library and look up the transport symbols.
///
/// Public so [acceptOnEndpoint] can be called in an isolate that has never
/// touched the engine.
NetSymbols? loadNetSymbols() {
  try {
    final handle = Platform.isAndroid || Platform.isLinux
        ? DynamicLibrary.open('librotelyx_mobile.so')
        : DynamicLibrary.process();
    return NetSymbols(handle);
  } on Object {
    return null;
  }
}

/// Rebuild a connection object around a handle another isolate produced.
RotelyxConnection? connectionFromHandle(int handle) {
  final symbols = loadNetSymbols();
  if (symbols == null || handle <= 0) return null;
  return RotelyxConnection._(symbols, handle);
}
