/// A voice call, as the rest of the application sees one.
///
/// # What this is a wire to
///
/// Nothing here encodes, encrypts, conceals loss or decides a bitrate. All of
/// that is in `rotelyx-media` and `rotelyx-codec` in the protocol repository,
/// reached through six C functions the mobile crate already exports. This file
/// is the shape those six take in Dart, and the reason it is a separate file
/// from the engine is that a browser has none of them.
///
/// # The shape of a call, in one paragraph
///
/// Open one on an established session. Every twenty milliseconds, hand it the
/// microphone's last 960 samples and it hands back a datagram to send; hand it
/// every datagram that arrives and pull decoded samples out to play. That is
/// the whole loop. The key comes from MLS, per sender, so a call is exactly as
/// protected as a message and for the same reason.
///
/// # Why the numbers are constants rather than parameters
///
/// [callFrameSamples] and [callSampleRate] are what the codec was built around:
/// a 960 sample frame at 48 kHz is twenty milliseconds, and the encoder needs a
/// forty millisecond window, which it gets by keeping one frame of history. The
/// audio layer has to produce exactly this and cannot negotiate, so the numbers
/// belong here where both sides can read them rather than in whichever file
/// happened to need them first.
library;

import 'dart:typed_data';

/// Samples in one frame. Twenty milliseconds at [callSampleRate].
const int callFrameSamples = 960;

/// Samples per second, mono, signed sixteen bit.
const int callSampleRate = 48000;

/// The largest datagram the codec will produce.
const int callMaxDatagram = 1200;

/// Bytes per encoded frame, which is what sets the bitrate.
///
/// 60 is 24 kbit/s and is the default the protocol's own command line uses.
/// 30 is 12 kbit/s, for a connection that cannot carry the first.
const int callBytesPerFrame = 60;

/// What a call reports about itself.
class CallStats {
  const CallStats({
    required this.participants,
    required this.concealed,
    required this.recoverable,
  });

  /// How many people are being decoded.
  final int participants;

  /// Frames that never arrived and were papered over.
  ///
  /// Not an error count. Concealment is what a live call does instead of
  /// waiting, and a handful of these is the ordinary condition of a mobile
  /// network. It is shown because a call that is breaking up should say so
  /// rather than leaving somebody to wonder whether the other person left.
  final int concealed;

  /// Whether this call would ask for a lost frame again rather than conceal it.
  ///
  /// False for a live call. Asking costs seconds of buffer, which is the wrong
  /// trade when somebody is waiting for an answer.
  final bool recoverable;
}

/// An open call.
abstract interface class RotelyxCall {
  /// Encode twenty milliseconds of microphone audio.
  ///
  /// [pcm] must be exactly [callFrameSamples] signed sixteen bit samples.
  /// Returns the datagram to send, or null for the first frame of a call:
  /// the encoder needs a forty millisecond window and is given twenty at a
  /// time, so the first produces no output. That is twenty milliseconds of
  /// added latency and the price of the longer window.
  Uint8List? capture(Int16List pcm);

  /// Take in a datagram that arrived.
  void deliver(Uint8List datagram);

  /// Pull the next frame out, to play.
  ///
  /// Pulled rather than pushed because the speaker runs on its own clock, and
  /// it is not the network's.
  ///
  /// **Silence rather than nothing** when nothing has arrived. That is the
  /// library's choice and it is the right one: a speaker is running whether or
  /// not the network is, and handing it nothing produces a click. It also means
  /// the audio loop never has to decide what to play when there is no audio,
  /// which is a decision that otherwise gets made differently in two places.
  ///
  /// Null only once the call is closed.
  Int16List? playback();

  CallStats? stats();

  void close();
}
