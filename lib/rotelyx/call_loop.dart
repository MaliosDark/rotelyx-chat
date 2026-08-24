/// The twenty millisecond loop a call is made of.
///
/// # What it does, in four lines
///
/// Take a frame from the microphone, encode it, send the datagram. Read any
/// datagram that arrived, hand it to the decoder, pull a frame out, play it.
/// Fifty times a second, in both directions, for as long as the call lasts.
///
/// Everything difficult is somewhere else: the codec and the per-sender keys
/// are in the Rust library, the transport is QUIC through a relay, the devices
/// are Android's. This is the clock that drives them.
///
/// # Why one timer and not two
///
/// Capture and playback could each have their own, and then the two would drift
/// against each other and against the devices, and the drift would show up as
/// audio that is fine for a minute and then is not. One tick does both, so
/// there is one clock to be wrong.
///
/// # Why it never awaits inside the tick
///
/// A tick that awaits can be re-entered by the next tick before it finishes,
/// and then two of them are pulling frames from the same queue in an order
/// nobody chose. The guard below drops a tick rather than overlapping it: a
/// dropped tick is twenty milliseconds, and an overlapped one is a call that
/// scrambles when the phone gets busy.
library;

import 'dart:async';

import '../platform/call_audio.dart';
import 'engine/call_native.dart';
import 'engine/net_native.dart';

/// What a running call is doing, for the interface to show.
class CallHealth {
  const CallHealth({
    required this.sent,
    required this.received,
    required this.concealed,
    required this.droppedCapture,
  });

  final int sent;
  final int received;

  /// Frames that never arrived and were papered over.
  ///
  /// The ordinary condition of a mobile network in small numbers. A number that
  /// climbs steadily is a call that is breaking up, and saying so is better
  /// than leaving somebody to wonder whether the other person walked away.
  final int concealed;

  /// Frames the microphone produced that nothing collected in time.
  final int droppedCapture;

  bool get isStruggling => concealed > 25 || droppedCapture > 25;
}

/// One call in progress.
class CallLoop {
  CallLoop({
    required RotelyxCall codec,
    required RotelyxConnection connection,
  })  : _codec = codec,
        _connection = connection;

  final RotelyxCall _codec;
  final RotelyxConnection _connection;

  Timer? _tick;
  var _busy = false;
  var _stopped = false;

  /// Whether a frame has been asked for and has not arrived yet.
  ///
  /// One at a time, so the encoder is fed in the order the microphone filled
  /// them. See `_outbound`.
  var _takingFrame = false;

  var _sent = 0;
  var _received = 0;
  var _dropped = 0;

  /// How often the loop runs. One frame.
  static const _period = Duration(milliseconds: 20);

  /// Open the devices and start.
  Future<void> start() async {
    await startAudio();
    if (_stopped) {
      await stopAudio();
      return;
    }

    _tick = Timer.periodic(_period, (_) => _oneFrame());
  }

  /// One tick: microphone out, network in.
  ///
  /// Deliberately not async. Everything in it is synchronous except the two
  /// device calls, and those are fired without waiting: a tick that waits is a
  /// tick the next one overlaps.
  void _oneFrame() {
    if (_busy || _stopped) return;
    _busy = true;

    try {
      _outbound();
      _inbound();
    } on Object {
      // A frame that fails is one frame. A call that ends because a single
      // encode threw is a call that ends for no reason a person can see.
    } finally {
      _busy = false;
    }
  }

  void _outbound() {
    // One request in flight at a time.
    //
    // A platform channel does not promise its replies arrive in the order they
    // were asked for, and this fired a new request every twenty milliseconds
    // without waiting for the last. So frames reached the encoder shuffled, and
    // an encoder with a forty millisecond window over a twenty millisecond hop
    // builds every frame on the one before it: the wrong previous frame makes
    // the overlap wrong.
    //
    // What that sounds like is a robotic voice rather than silence or
    // distortion, and it survives every check there is. The frames are whole,
    // they authenticate, they decode, and the far side counts every one of
    // them. Measured on a pure tone it came back at 0.25 correlation where a
    // tone is 0.99: each twenty millisecond piece intact and none of them in
    // the right place.
    //
    // `_busy` did not prevent this. It is set and cleared inside one
    // synchronous tick, so it guards the tick and not the request.
    if (_takingFrame) return;
    _takingFrame = true;

    unawaited(takeFrame().whenComplete(() => _takingFrame = false).then((pcm) {
      if (pcm == null || _stopped) return;

      // Muted means not encoding at all. A muted microphone still produces
      // frames, and frames of silence still cost bandwidth and still tell an
      // observer that somebody is on a call.
      if (_muted) return;

      final datagram = _codec.capture(pcm);
      // Null for the first frame of a call, while the encoder fills its forty
      // millisecond window. Not a failure.
      if (datagram == null) return;

      if (_connection.send(datagram)) _sent++;
    }));
  }

  void _inbound() {
    // Every datagram waiting, not one. A network that delivered two while this
    // loop was busy has two ready, and taking one per tick means the queue only
    // ever grows.
    for (var i = 0; i < 4; i++) {
      final datagram = _connection.receive(timeout: Duration.zero);
      if (datagram == null) break;
      _codec.deliver(datagram);
      _received++;
    }

    final pcm = _codec.playback();
    // Never null on a live call: the library hands back silence rather than
    // nothing, because a speaker with nothing to play clicks.
    if (pcm != null) unawaited(playFrame(pcm));
  }

  /// What the call is doing.
  Future<CallHealth> health() async {
    final stats = _codec.stats();
    _dropped = await droppedFrames();

    return CallHealth(
      sent: _sent,
      received: _received,
      concealed: stats?.concealed ?? 0,
      droppedCapture: _dropped,
    );
  }

  /// Earpiece or speakerphone.
  Future<void> useSpeakerphone(bool loud) => useSpeaker(loud);

  /// Stop sending, without ending the call.
  ///
  /// Done by not encoding rather than by muting the device. A muted microphone
  /// still produces frames, and frames of silence are still frames: they cost
  /// bandwidth and they tell an observer somebody is on a call. Not sending
  /// costs nothing and says nothing.
  void mute(bool quiet) => _muted = quiet;

  bool _muted = false;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;

    _tick?.cancel();
    _tick = null;

    // Devices first, then the codec, then the connection. The other order
    // leaves the capture thread handing frames to an encoder that has been
    // freed, and the window between them is exactly one tick wide.
    await stopAudio();
    _codec.close();
    _connection.close();
  }
}
