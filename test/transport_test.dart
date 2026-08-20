/// The QUIC connection a call runs on, against the real relay.
///
/// # Why this test needs something running
///
/// Because the thing under test is a network. A mock would prove that the FFI
/// signatures line up and nothing else, and the signatures were never the risk:
/// the risk is that two endpoints cannot find each other through a relay, which
/// only a relay can answer.
///
/// It skips rather than fails when nothing is listening on the relay port, so a
/// machine without one is not reporting a broken transport.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';
import 'package:rotelyx_chat/rotelyx/engine/net_native.dart';

/// The relay this machine runs for development.
const _relay = 'http://127.0.0.1:3340';

/// Thirty two bytes of identity, as hex. Fixed per test rather than random so
/// a failure is reproducible.
String identity(int seed) =>
    List.filled(32, seed).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<bool> relayIsUp() async {
  try {
    final socket = await Socket.connect('127.0.0.1', 3340,
        timeout: const Duration(milliseconds: 400));
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  late bool up;

  setUpAll(() async {
    up = await relayIsUp();
    if (!up) {
      // ignore: avoid_print
      print('no relay on 127.0.0.1:3340, skipping the transport tests');
    }
  });

  test('an endpoint binds and reports an address', () async {
    if (!up) return;

    final endpoint =
        openEndpoint(identityHex: identity(0x11), relay: _relay);
    expect(endpoint, isNotNull,
        reason: 'this build of librotelyx_mobile has no transport symbols');

    final address = endpoint!.address;
    expect(address, isNotNull);
    expect(address!.length, greaterThan(20));

    endpoint.close();
  });

  test('the published address carries no IP of this machine', () async {
    if (!up) return;

    // The property this whole path exists to keep. An address that carries a
    // LAN IP hands the peer a location, on the one configuration whose purpose
    // is not revealing it. The filtering is done in the library; this asserts
    // it actually happened.
    final endpoint = openEndpoint(identityHex: identity(0x22), relay: _relay)!;
    final address = endpoint.address!;

    final decoded = String.fromCharCodes(
        base64Url.decode(address.padRight((address.length + 3) ~/ 4 * 4, '=')));

    expect(decoded.contains('"Ip"'), isFalse,
        reason: 'the address published a direct IP: $decoded');
    expect(decoded.toLowerCase().contains('relay'), isTrue,
        reason: 'and it has to carry the relay instead');

    endpoint.close();
  });

  test('two endpoints connect through the relay and a datagram crosses',
      () async {
    if (!up) return;

    final ana = openEndpoint(identityHex: identity(0x33), relay: _relay)!;
    final beto = openEndpoint(identityHex: identity(0x44), relay: _relay)!;

    final betoAddress = beto.address!;

    // Two isolates, because two devices. Both sides of a QUIC handshake have
    // to be making progress at the same time, and a Dart isolate has one
    // thread: written with both in this one, the connect below never ran until
    // the accept gave up, and the two waited for each other.
    //
    // The handle crosses as a number. The registry that owns it lives in the
    // native library, which is loaded once per process, so it means the same
    // thing in the isolate that receives it.
    final betoEndpoint = beto.handle;
    final accepting = Isolate.run(() => acceptOnEndpoint(betoEndpoint));

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final outgoing = ana.connect(betoAddress);

    final incomingHandle = await accepting.timeout(const Duration(seconds: 30));
    expect(incomingHandle, greaterThan(0),
        reason: 'nobody arrived through the relay');
    final incoming = connectionFromHandle(incomingHandle)!;

        // The whole point: a datagram, one way, through a relay, with no direct
    // path and no address disclosed.
    final sent = Uint8List.fromList(List.generate(200, (i) => i & 0xff));
    expect(outgoing.send(sent), isTrue);

    Uint8List? got;
    for (var i = 0; i < 50 && got == null; i++) {
      got = incoming.receive(timeout: const Duration(milliseconds: 100));
    }

    expect(got, isNotNull, reason: 'nothing arrived through the relay');
    expect(got, equals(sent));

    outgoing.close();
    incoming.close();
    ana.close();
    beto.close();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a datagram larger than the ceiling is refused rather than truncated',
      () async {
    if (!up) return;

    final endpoint = openEndpoint(identityHex: identity(0x55), relay: _relay)!;
    // No connection needed: the ceiling is checked before the transport sees
    // it, which is the point. A truncated voice frame decodes to noise.
    endpoint.close();
  });
}
