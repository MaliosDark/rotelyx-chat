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
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../platform/call_audio.dart';
import 'call_api.dart';
import 'dtmf.dart';
import 'engine/net_backend.dart';

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

  /// Frames the encoder produced nothing for, and datagrams the transport
  /// would not take. See the diagnostic line.
  var _noDatagram = 0;
  var _refused = 0;
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

      _diagnose('capture', pcm);

      _mixDigit(pcm);
      _remember(_speaking, pcm);
      final datagram = _codec.capture(pcm);
      // Null for the first frame of a call, while the encoder fills its forty
      // millisecond window. Not a failure.
      if (datagram == null) {
        _noDatagram++;
        return;
      }

      if (_connection.send(datagram)) {
        _sent++;
      } else {
        _refused++;
      }
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
    if (pcm != null) {
      _diagnose('playback', pcm);
      _remember(_hearing, pcm);
    }
    // Never null on a live call: the library hands back silence rather than
    // nothing, because a speaker with nothing to play clicks.
    if (pcm != null) _play(pcm);
  }

  /// Hand one frame to the speaker, in the order it was decoded.
  ///
  /// # Why this is not simply fired off, and not simply awaited
  ///
  /// It used to be `unawaited(playFrame(pcm))`, once every twenty
  /// milliseconds, with no wait for the last. A platform channel does not
  /// promise its replies come back in the order they were sent, and makes no
  /// promise at all about the order two outstanding calls reach the other
  /// side. So frames reached the speaker shuffled, and shuffled twenty
  /// millisecond frames of speech are interference rather than a voice.
  ///
  /// It is the same fault that was found and fixed on the capture side, where
  /// the encoder's window made it audible as a robotic voice. Nothing was
  /// changed here at the time. Measuring the speaker showed why it mattered:
  /// neighbouring sample correlation alternating between 0.95 and 0.01 frame
  /// to frame, which is a voice interleaved with noise.
  ///
  /// Awaiting it in the caller is not the answer either: this runs on a timer
  /// that has to keep its own time, and a tick that waits for the device is a
  /// tick that no longer arrives every twenty milliseconds.
  ///
  /// # The policy, which is the desktop's
  ///
  /// `rotelyx-audio`'s `device.rs` hands the loudspeaker a queue that plays in
  /// order and drops the **oldest** past [_maxBacklog], because a listener
  /// past that point is hearing the past rather than the present and a buffer
  /// that only grows turns a stall into a permanently late call. Android's
  /// `AudioTrack` is that queue; what is missing on this side is only the
  /// ordering, because Dart reaches it through an asynchronous channel. So
  /// this keeps one call in flight and the rest in a queue, in order, bounded
  /// the same way and dropping from the same end.
  void _play(Int16List pcm) {
    _pending.add(pcm);
    while (_pending.length > _maxBacklog) {
      _pending.removeFirst();
    }
    if (!_playing) _drain();
  }

  void _drain() {
    if (_stopped || _pending.isEmpty) {
      _playing = false;
      return;
    }

    _playing = true;
    final next = _pending.removeFirst();
    unawaited(playFrame(next).whenComplete(_drain));
  }

  /// Frames that may pile up before the oldest is dropped.
  ///
  /// Twenty of them: 400 ms at [callFrameSamples] a frame, which is the figure
  /// `MAX_BACKLOG` uses on the desktop and for the reason written there.
  static const _maxBacklog = 20;

  final _pending = Queue<Int16List>();
  bool _playing = false;

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

  // ---------------------------------------------------------------------
  // Touch tones
  // ---------------------------------------------------------------------

  Int16List? _digit;
  var _digitAt = 0;

  /// Send one key press, heard by the other side.
  ///
  /// Mixed into the microphone rather than replacing it, so a person who is
  /// talking while they press does not cut themselves off. See `dtmf.dart` for
  /// why this is in band and what that costs.
  ///
  /// A press while one is still sounding replaces it. Two tones at once are a
  /// third pair of frequencies and decode as neither key, which is worse than
  /// losing the first.
  void sendDigit(String key) {
    final samples = samplesFor(key);
    if (samples == null) return;
    _digit = samples;
    _digitAt = 0;
  }

  /// Add whatever of the current tone belongs in this frame.
  ///
  /// Summed and then clamped, because a tone laid on top of speech that is
  /// already loud would otherwise wrap around: sixteen bit addition that
  /// overflows turns a peak into its opposite, which is a click on every
  /// frame it happens in.
  void _mixDigit(Int16List pcm) {
    final tone = _digit;
    if (tone == null) return;

    for (var i = 0; i < pcm.length && _digitAt < tone.length; i++, _digitAt++) {
      final sum = pcm[i] + tone[_digitAt];
      pcm[i] = sum > 32767 ? 32767 : (sum < -32768 ? -32768 : sum);
    }

    if (_digitAt >= tone.length) {
      _digit = null;
      _digitAt = 0;
    }
  }

  // ---------------------------------------------------------------------
  // Diagnosis, compiled out unless asked for
  // ---------------------------------------------------------------------

  /// On only under `--dart-define=ROTELYX_CALL_DIAG=1`, so a shipped build
  /// carries none of this.
  static const _diag =
      bool.fromEnvironment('ROTELYX_CALL_DIAG', defaultValue: false);

  final _seen = <String, int>{};

  /// Say whether a frame sounds like a voice or like noise.
  ///
  /// The measure is correlation between neighbouring samples, which is what
  /// found the last fault of this shape: speech is above 0.9 because a sample
  /// resembles the one before it, and broadband noise is near zero because it
  /// does not. Reported for the microphone and for the speaker separately, so
  /// a call that captures a voice and plays noise is distinguishable from one
  /// that captures noise to begin with.
  // ---------------------------------------------------------------------
  // What the call looks like
  // ---------------------------------------------------------------------

  /// How many frames of history the ring shows. 64, which at a frame every
  /// twenty milliseconds is the last one and a quarter seconds: long enough
  /// to see the shape of a word, short enough to feel immediate.
  static const historyLength = 64;

  final _speaking = Float64List(historyLength);
  final _hearing = Float64List(historyLength);
  var _at = 0;

  /// This device's own voice, oldest first, each from zero to one.
  Float64List get speaking => _ordered(_speaking);

  /// The other side's, the same way.
  Float64List get hearing => _ordered(_hearing);

  /// Newest sample of either, for anything that wants a single number.
  double get loudest => math.max(
        _speaking[(_at - 1) % historyLength],
        _hearing[(_at - 1) % historyLength],
      );

  /// One frame's loudness, kept in a ring so nothing is allocated per frame.
  ///
  /// Root mean square rather than peak, because peak jumps on a single sample
  /// and a display that jumps with it reads as noise rather than as a voice.
  /// Scaled against a quarter of full scale, which is where speech sits once
  /// the capture gain has done its work, and clamped: past that the ring is
  /// full and staying full is the honest picture.
  void _remember(Float64List into, Int16List pcm) {
    var sum = 0.0;
    for (final s in pcm) {
      sum += s.toDouble() * s.toDouble();
    }
    final rms = math.sqrt(sum / pcm.length);
    into[_at % historyLength] = (rms / 8192.0).clamp(0.0, 1.0);

    // Advanced by the capture side alone, so the two histories share a clock
    // and a moment in one lines up with the same moment in the other.
    if (identical(into, _speaking)) _at++;
  }

  Float64List _ordered(Float64List ring) {
    final out = Float64List(historyLength);
    for (var i = 0; i < historyLength; i++) {
      out[i] = ring[(_at + i) % historyLength];
    }
    return out;
  }

  /// How much of a frame sits at one frequency.
  ///
  /// The same arithmetic the keypad test uses to check a touch tone is the
  /// tone it claims to be, and the same a receiver would use to read one.
  static double _energyAt(Int16List pcm, double freq) {
    var real = 0.0;
    var imaginary = 0.0;
    for (var i = 0; i < pcm.length; i++) {
      final angle = 2 * math.pi * freq * i / callSampleRate;
      real += pcm[i] * math.cos(angle);
      imaginary += pcm[i] * math.sin(angle);
    }
    return math.sqrt(real * real + imaginary * imaginary) / pcm.length;
  }

  void _diagnose(String where, Int16List pcm) {
    if (!_diag) return;

    final n = (_seen[where] ?? 0) + 1;
    _seen[where] = n;
    if (n % 50 != 0) return; // once a second at twenty milliseconds a frame

    // Refreshed here rather than only in `health`, which the screen calls and
    // a call without a screen therefore never does.
    //
    // This is the count of frames the capture thread threw away because
    // nothing collected them in time. It matters more than it looks: the
    // encoder has a forty millisecond window over a twenty millisecond hop, so
    // every frame is built on the one before it, and a frame that was dropped
    // makes the next one overlap audio that is not adjacent to it. That is a
    // voice that grinds, and it is invisible to every other counter here
    // because nothing failed: the frames that did arrive all encoded, all
    // sent, and all decoded.
    if (where == 'playback') unawaited(droppedFrames().then((d) => _dropped = d));

    var sumSq = 0.0;
    var sumProd = 0.0;
    var peak = 0;
    for (var i = 0; i < pcm.length; i++) {
      final v = pcm[i].toDouble();
      sumSq += v * v;
      if (i > 0) sumProd += v * pcm[i - 1].toDouble();
      final a = pcm[i].abs();
      if (a > peak) peak = a;
    }

    final correlation = sumSq == 0 ? 0.0 : sumProd / sumSq;
    final rms = math.sqrt(sumSq / pcm.length);

    // The codec's own counters beside the measurement, because a frame that
    // cannot be turned into sound is concealed rather than reported, and
    // concealment is comfort noise: low, constant, and uncorrelated. That is
    // indistinguishable from a corrupted payload by listening, and these two
    // numbers tell them apart. Only on the playback line; the microphone has
    // nothing to conceal.
    // `nodatagram` is the encoder declining to produce one and `refused` is
    // the transport declining to carry it. A call that captures a voice and
    // stops sending is one or the other, and they are not the same fault: one
    // is the codec, the other is the connection.
    final counts = where == 'playback'
        ? ' sent=$_sent received=$_received '
            'concealed=${_codec.stats()?.concealed ?? -1} '
            'nodatagram=$_noDatagram refused=$_refused '
            'droppedcapture=$_dropped'
        : '';

    // Where the energy sits, which is what correlation cannot say.
    //
    // Correlation between neighbouring samples separates speech from
    // broadband noise and nothing else: it measures smoothness, and a hum at
    // a hundred hertz is perfectly smooth. Reporting 0.99 as "a voice" was
    // wrong, and it was wrong for several hours while somebody listened to
    // something that was not one.
    //
    // Speech puts its energy between about 300 and 3000 hertz and has to have
    // some in each part of that. A rumble has it all underneath. Four
    // frequencies is enough to tell those apart and costs four passes over
    // 960 samples.
    final bands = [100.0, 400.0, 1200.0, 2600.0]
        .map((f) => _energyAt(pcm, f).round())
        .join('/');

    debugPrint('ROTELYX_DIAG $where frame=$n '
        'correlation=${correlation.toStringAsFixed(3)} '
        'rms=${rms.toStringAsFixed(0)} peak=$peak '
        'bands=$bands$counts');
  }

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
