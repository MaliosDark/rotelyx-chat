/// The native engine, exercised through the same FFI wrapper a phone uses.
///
/// # Why this can run here
///
/// `lib/rotelyx/engine/native.dart` is not Android-specific. It opens a shared
/// library and speaks a JSON ABI to it, and Linux can do both. So the wrapper
/// that Android will use is the wrapper this test drives, on this machine, with
/// no handset and no emulator.
///
/// What that leaves untested for Android is the packaging: whether the `.so`
/// ends up in the APK and whether the loader finds it. Everything above that,
/// which is all of the code, is covered here.
///
/// # Running it
///
///   tool/native/build-host.sh
///   LD_LIBRARY_PATH=build/native flutter test test/native_engine_test.dart
///
/// Skipped rather than failed when the library is absent, because a contributor
/// who has not built it should not see a red suite for a step they have not
/// been asked to take.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/engine/api.dart';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';

void main() {
  final engine = createEngine();

  // One probe, so the reason is reported once rather than thirty times.
  final available = engine.ready;
  final why = engine.error;

  group('the native engine', () {
    setUp(() {
      if (!available) {
        markTestSkipped('no native library loaded: $why');
      }
    });

    test('reports a protocol version and a group ceiling', () {
      if (!available) return;
      expect(engine.version, isNotEmpty);
      expect(engine.version, startsWith('rotelyx/'));
      expect(engine.maxMembers, greaterThan(1));
    });

    test('derives the same rendezvous tag for the same phrase', () {
      if (!available) return;
      final a = engine.rendezvousTag('a shared meeting phrase');
      final b = engine.rendezvousTag('a shared meeting phrase');
      final other = engine.rendezvousTag('a different meeting phrase');

      expect(a, equals(b), reason: 'the derivation must be deterministic');
      expect(a, isNot(equals(other)));
      expect(a.length, 64, reason: '32 bytes as hex');
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);
    });

    test('seals under a tag and opens it again', () {
      if (!available) return;
      final tag = engine.rendezvousTag('a shared meeting phrase');
      final payload = base64Encode(utf8.encode('the first thing either side says'));

      final envelope = engine.sealUnder(tag, payload);
      expect(envelope, isNot(equals(payload)));
      expect(engine.openUnder(envelope, tag), equals(payload));
    });

    test('a wrong tag does not open an envelope', () {
      if (!available) return;
      final envelope = engine.sealUnder(
          engine.rendezvousTag('the right phrase'), base64Encode(utf8.encode('hello')));

      expect(() => engine.openUnder(envelope, engine.rendezvousTag('the wrong phrase')),
          throwsA(isA<RotelyxEngineError>()));
    });

    test('a passphrase seals a blob and reopens it', () {
      if (!available) return;
      final key = engine.newKey('a passphrase long enough to be accepted');
      addTearDown(key.dispose);

      final data = base64Encode(utf8.encode('a conversation, written down'));
      final sealed = engine.sealBlob(key, data);
      expect(engine.openBlob(key, sealed), equals(data));
    });

    test('a different passphrase does not reopen it', () {
      if (!available) return;
      final key = engine.newKey('the passphrase it was sealed under');
      addTearDown(key.dispose);
      final sealed = engine.sealBlob(key, base64Encode(utf8.encode('private')));

      // The unlock derives a key from the blob's own parameters, so this is the
      // real path a wrong passphrase takes rather than a synthetic mismatch.
      final wrong = engine.unlockKey('some other passphrase entirely', sealed);
      addTearDown(wrong.dispose);
      expect(() => engine.openBlob(wrong, sealed),
          throwsA(isA<RotelyxEngineError>()));
    });

    test('a session has a key package and a post-quantum public key', () {
      if (!available) return;
      final session = engine.newSession('Ana');
      addTearDown(session.dispose);

      expect(session.keyPackage(), isNotEmpty);

      // X-Wing: ML-KEM-768 at 1184 bytes plus X25519 at 32, so 1216 encoded as
      // base64 is 1624 characters. This is the number that makes an invitation
      // too large for a QR code, so it is worth asserting rather than assuming.
      final pk = session.hybridPublicKey();
      expect(pk.length, 1624);
      expect(base64Decode(pk).length, 1216);
    });

    test('two members pair, agree a safety number, and exchange a message', () {
      if (!available) return;

      // The whole handshake, both sides in this process. No mailbox: the
      // envelopes are handed across directly, because what is under test is the
      // engine wrapper rather than the transport.
      final host = engine.newSession('Ana');
      final guest = engine.newSession('Beto');
      addTearDown(host.dispose);
      addTearDown(guest.dispose);

      host.found();
      expect(host.memberCount, 1);

      final invitation = host.invite(guest.keyPackage());
      guest.join(invitation.welcome, invitation.ratchetTree);

      // The post-quantum step, which is separate from MLS and layered over it.
      guest.openPq(host.encapsulateTo(guest.hybridPublicKey()));
      final commit = host.commitPq();
      guest.receive(commit);

      expect(host.memberCount, 2, reason: 'the host should see the group of two');
      expect(guest.memberCount, 2);
      expect(guest.epoch, equals(host.epoch),
          reason: 'both sides must be at the same epoch after the commit');

      final number = host.safetyNumber();
      expect(number, isNotEmpty);
      expect(guest.safetyNumber(), equals(number),
          reason: 'a differing safety number is what a machine in the middle '
              'would produce, so equality here is the property that matters');

      const said = 'the first message either of them sent';
      expect(guest.receive(host.send(said)), equals(said));
      expect(host.receive(guest.send('and the reply')), equals('and the reply'));
    });

    test('a session survives being sealed and restored', () {
      if (!available) return;
      final key = engine.newKey('a passphrase long enough to be accepted');
      addTearDown(key.dispose);

      final host = engine.newSession('Ana');
      final guest = engine.newSession('Beto');
      addTearDown(guest.dispose);

      host.found();
      final invitation = host.invite(guest.keyPackage());
      guest.join(invitation.welcome, invitation.ratchetTree);
      guest.openPq(host.encapsulateTo(guest.hybridPublicKey()));
      guest.receive(host.commitPq());

      final before = host.safetyNumber();
      final blob = host.sealSession(key);
      host.dispose();

      final restored = engine.unsealSession(blob, key);
      addTearDown(restored.dispose);

      // The identical safety number is the whole claim: the restored session is
      // the same member of the same group, not a lookalike.
      expect(restored.safetyNumber(), equals(before));
      expect(guest.receive(restored.send('sent after a restart')),
          equals('sent after a restart'));
    });

    test('a group of one has no tag to be addressed at', () {
      if (!available) return;
      // Worth pinning down, because it is not obvious and it is the reason the
      // test below has to pair first. The tag key comes from the group secret,
      // which is agreed when a second member arrives. A lone founder is not
      // reachable, and the engine says so rather than returning something.
      final alone = engine.newSession('Ana');
      addTearDown(alone.dispose);
      alone.found();

      expect(alone.myTag, throwsA(isA<RotelyxEngineError>()));
    });

    test('addressing produces hex tags of the right shape', () {
      if (!available) return;
      final host = engine.newSession('Ana');
      final guest = engine.newSession('Beto');
      addTearDown(host.dispose);
      addTearDown(guest.dispose);

      host.found();
      final invitation = host.invite(guest.keyPackage());
      guest.join(invitation.welcome, invitation.ratchetTree);
      guest.openPq(host.encapsulateTo(guest.hybridPublicKey()));
      guest.receive(host.commitPq());

      final mine = host.myTag();
      expect(mine.length, 64, reason: '32 bytes as hex');
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(mine), isTrue);

      // A lookback of two asks for this hour and the two before it, so the
      // current tag has to be among them or a client would stop hearing itself
      // the moment the hour turned.
      expect(host.myPollingTags(2), contains(mine));

      // The host addresses the guest and the guest addresses the host, so
      // neither should be writing to its own slot.
      expect(host.recipientTags(), isNotEmpty);
      expect(host.recipientTags(), isNot(contains(mine)));
    });

    test('a bad handle is an error rather than a crash', () {
      if (!available) return;
      // The registry hands out integers precisely so that a wrapper bug cannot
      // do worse than this.
      final session = engine.newSession('Ana');
      session.dispose();
      expect(session.keyPackage, throwsA(isA<RotelyxEngineError>()));
    });
  });

  test('the library is where the build script puts it', () {
    // Not an assertion about the engine, a signpost. A skipped group above with
    // no explanation is the kind of thing that stays skipped for months.
    if (available) return;
    stdout.writeln('\n  native engine not loaded: $why');
    stdout.writeln('  build it with:  tool/native/build-host.sh');
    stdout.writeln('  then:           LD_LIBRARY_PATH=build/native flutter test\n');
  });
}
