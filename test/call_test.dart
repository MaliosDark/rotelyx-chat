/// A voice call, against the real library.
///
/// # What is under test and what is not
///
/// Not the codec. `rotelyx-codec` and `rotelyx-media` are tested in the
/// protocol repository, where the arithmetic is. What is tested here is the
/// binding: that the six C functions are found, that a frame of audio survives
/// the round trip through them, and that the buffers on this side are the sizes
/// the library expects.
///
/// That last part is the one worth having a test for. Every one of these calls
/// takes a raw pointer and a length, and getting a length wrong does not throw:
/// it reads somebody else's memory, or writes into it, and the symptom is a
/// crash somewhere unrelated an hour later.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/call_api.dart';
import 'package:rotelyx_chat/rotelyx/engine/api.dart';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';

/// The identifier a call is keyed with. Fixed here because these tests are not
/// about the binding; `two calls in one epoch` below is the one that varies it.
const aTestCall = 'a-test-call-0001';


/// Two sessions in one group, which is what a call needs.
({RotelyxSession host, RotelyxSession guest}) paired(RotelyxEngine engine) {
  final host = engine.newSession('Ana');
  final guest = engine.newSession('Beto');

  // The whole handshake, both sides in this process. No mailbox: the envelopes
  // are handed across directly, because what is under test is the media path
  // rather than the transport.
  host.found();

  final invitation = host.invite(guest.keyPackage());
  guest.join(invitation.welcome, invitation.ratchetTree);

  // The post-quantum step, which is layered over MLS rather than part of it.
  // A call keys from the group secret, so it has to be the settled one.
  guest.openPq(host.encapsulateTo(guest.hybridPublicKey()));
  guest.receive(host.commitPq());

  return (host: host, guest: guest);
}

/// A second of a 440 Hz tone, in frames.
///
/// A tone rather than noise, because what comes back out of a lossy codec can
/// be compared against what went in only if the input has structure. Noise
/// decodes to different noise and proves nothing.
List<Int16List> tone({int frames = 50}) => [
      for (var f = 0; f < frames; f++)
        Int16List.fromList([
          for (var i = 0; i < callFrameSamples; i++)
            (sin(2 * pi * 440 * ((f * callFrameSamples) + i) / callSampleRate) *
                    12000)
                .round(),
        ]),
    ];

void main() {
  late RotelyxEngine engine;

  setUpAll(() {
    engine = createEngine();
  });

  test('the media symbols are in the library', () {
    // A library built before calls existed returns null rather than throwing,
    // and this asserts we are not silently on that path.
    final pair = paired(engine);
    final call = openNativeCall(pair.host, call: aTestCall);

    expect(call, isNotNull,
        reason: 'this build of librotelyx_mobile has no call symbols');
    call?.close();
  });

  test('a call opens on a paired session and closes', () {
    final pair = paired(engine);
    final call = openNativeCall(pair.host, call: aTestCall)!;

    final stats = call.stats();
    expect(stats, isNotNull);
    expect(stats!.recoverable, isFalse,
        reason: 'a live call conceals loss rather than waiting for it again');

    call.close();
    // Closing twice must not double free. The second is a no-op by contract.
    call.close();
  });

  test('the first frame produces nothing, and the rest produce datagrams', () {
    final pair = paired(engine);
    final call = openNativeCall(pair.host, call: aTestCall)!;

    final frames = tone(frames: 5);
    final produced = [for (final f in frames) call.capture(f)];

    expect(produced.first, isNull,
        reason: 'the encoder needs a 40 ms window and is given 20 at a time, '
            'so the first frame fills history and emits nothing');

    for (final datagram in produced.skip(1)) {
      expect(datagram, isNotNull);
      expect(datagram!.length, greaterThan(0));
      expect(datagram.length, lessThanOrEqualTo(callMaxDatagram));
    }

    call.close();
  });

  test('two calls in one epoch do not repeat a keystream', () {
    // The regression test for the worst defect the media layer has had. The
    // group secret and the sender index are fixed for an MLS epoch, ordinary
    // messages do not advance an epoch, and the frame counter restarts at zero
    // every time a call opens. So before the call identifier was bound in,
    // hanging up and dialling again encrypted the second call's first frame
    // under the first call's first key and nonce.
    final pair = paired(engine);
    final frames = tone(frames: 4).toList();

    List<Uint8List> speak(String call) {
      final c = openNativeCall(pair.host, call: call)!;
      final out = <Uint8List>[];
      for (final f in frames) {
        final d = c.capture(f);
        if (d != null) out.add(d);
      }
      c.close();
      return out;
    }

    final first = speak('call-one-00000001');
    final second = speak('call-two-00000002');

    expect(first, isNotEmpty);
    expect(first.length, second.length);

    for (var i = 0; i < first.length; i++) {
      expect(first[i], isNot(equals(second[i])),
          reason: 'frame $i was identical across two calls, which is nonce reuse');
    }

    // And the second call's listener must make nothing of the first call's
    // audio: a frame keyed for another call does not authenticate, so nothing
    // it delivers ever reaches the speaker.
    final listening = openNativeCall(pair.guest, call: 'call-two-00000002')!;
    for (final d in first) {
      listening.deliver(d);
    }
    final played = listening.playback();
    expect(played, isNotNull);
    expect(played!.every((sample) => sample == 0), isTrue,
        reason: 'audio from another call reached the speaker');
    listening.close();
  });

  test('a call refuses an identifier too short to key it', () {
    final pair = paired(engine);
    expect(() => openNativeCall(pair.host, call: 'tiny'), throwsA(anything));
  });

  test('audio crosses from one member to the other', () {
    // The whole point, end to end: Ana speaks, the datagrams are handed to
    // Beto, and Beto has audio to play. The keys come from MLS, so this only
    // works because the two are in the same group.
    final pair = paired(engine);
    final ana = openNativeCall(pair.host, call: aTestCall)!;
    final beto = openNativeCall(pair.guest, call: aTestCall)!;

    var delivered = 0;
    for (final frame in tone(frames: 20)) {
      final datagram = ana.capture(frame);
      if (datagram == null) continue;
      beto.deliver(datagram);
      delivered++;
    }

    expect(delivered, greaterThan(15));

    var heard = 0;
    var loudest = 0;
    for (var i = 0; i < 30; i++) {
      final pcm = beto.playback();
      if (pcm == null) continue;
      heard++;
      expect(pcm.length, callFrameSamples);
      for (final s in pcm) {
        final level = s.abs();
        if (level > loudest) loudest = level;
      }
    }

    expect(heard, greaterThan(0), reason: 'nothing came out the other end');
    expect(loudest, greaterThan(1000),
        reason: 'what came out is silence, so the frames decoded to nothing');

    ana.close();
    beto.close();
  });

  test('a frame of the wrong length is refused rather than read past', () {
    // The reason this test exists: every one of these calls takes a pointer
    // and a length. A wrong length does not throw, it reads somebody else's
    // memory, and the symptom appears somewhere unrelated much later.
    final pair = paired(engine);
    final call = openNativeCall(pair.host, call: aTestCall)!;

    expect(() => call.capture(Int16List(callFrameSamples - 1)),
        throwsA(isA<ArgumentError>()));
    expect(() => call.capture(Int16List(callFrameSamples + 1)),
        throwsA(isA<ArgumentError>()));

    call.close();
  });

  test('a datagram that is too large is dropped, not passed on', () {
    final pair = paired(engine);
    final call = openNativeCall(pair.host, call: aTestCall)!;

    // Nothing should happen, and specifically nothing should be written past
    // the end of a buffer sized for the maximum.
    call.deliver(Uint8List(callMaxDatagram + 1));
    call.deliver(Uint8List(0));

    expect(call.stats(), isNotNull, reason: 'the call survived both');
    call.close();
  });

  test('playback gives silence rather than nothing before anything arrives', () {
    // Written expecting null and corrected against the library, because the
    // library is right: a speaker is running whether or not the network is,
    // and a call that hands it nothing produces a click. Silence is the frame
    // that belongs there.
    //
    // It also means the audio loop never has to decide what to play when there
    // is no audio, which is the kind of decision that gets made differently in
    // two places.
    final pair = paired(engine);
    final call = openNativeCall(pair.host, call: aTestCall)!;

    final pcm = call.playback();
    expect(pcm, isNotNull);
    expect(pcm!.length, callFrameSamples);
    expect(pcm.every((s) => s == 0), isTrue, reason: 'and it is silent');

    call.close();
  });

  test('a closed call answers nothing rather than crashing', () {
    final pair = paired(engine);
    final call = openNativeCall(pair.host, call: aTestCall)!;
    call.close();

    expect(call.capture(Int16List(callFrameSamples)), isNull);
    expect(call.playback(), isNull);
    expect(call.stats(), isNull);
    call.deliver(Uint8List(10));
  });
}
