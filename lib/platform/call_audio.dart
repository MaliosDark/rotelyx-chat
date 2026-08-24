/// The microphone and the speaker.
///
/// A wire to `android/.../CallAudio.kt`, which produces and consumes exactly
/// one thing: 960 signed sixteen bit samples, mono, at 48 kHz. That is twenty
/// milliseconds and it is what the codec was built around.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'os.dart' as os;

const MethodChannel _channel = MethodChannel('rotelyx/call-audio');

/// Whether this platform has the audio devices wired up.
bool get audioIsBuilt => os.isMobile;

/// Ask for the microphone. False when it was refused.
Future<bool> permitMicrophone() async {
  if (!audioIsBuilt) return false;
  try {
    return await _channel.invokeMethod<bool>('permit') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Open both devices. Throws [AudioRefused] with a reason.
Future<void> startAudio() async {
  if (!audioIsBuilt) {
    throw const AudioRefused('calls are not built for this platform yet');
  }
  try {
    await _channel.invokeMethod<bool>('start');
  } on PlatformException catch (e) {
    throw AudioRefused(e.code == 'permission'
        ? 'The microphone permission was refused.'
        : e.message ?? 'The audio devices would not open.');
  } on MissingPluginException {
    throw const AudioRefused('this build has no audio channel');
  }
}

/// The oldest captured frame, or null when none is waiting.
///
/// Null is the ordinary answer between frames. The devices run on their own
/// clock and this is asked on the caller's, and the two are never quite the
/// same.
Future<Int16List?> takeFrame() async {
  if (!audioIsBuilt) return null;
  try {
    final bytes = await _channel.invokeMethod<Uint8List>('take');
    if (bytes == null || bytes.lengthInBytes < 2) return null;
    // Assembled from the bytes, rather than viewed through them.
    //
    // This was `bytes.buffer.asInt16List(0, ...)`, which reads from the start of
    // the buffer behind this list rather than from where the list itself
    // starts. A `Uint8List` off a platform channel is a window onto a larger
    // buffer holding the whole reply, so that read begins in the reply's header
    // and runs off the end of the audio.
    //
    // Naming the offset fixes that one thing and leaves two more standing: the
    // offset has to be even or the call throws, and the machine has to read
    // sixteen bit values the same way round as Kotlin wrote them. Each is true
    // most of the time and none is stated anywhere.
    //
    // A tone written into the frame in Kotlin reached the far end as broadband
    // noise, and the fault was measured to this stretch: Kotlin, the channel,
    // and this line. Doing the arithmetic here answers all three questions at
    // once and costs a loop over nine hundred and sixty values, which is far
    // less than the codec that runs immediately after it.
    final samples = Int16List(bytes.lengthInBytes ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      final low = bytes[i * 2];
      final high = bytes[i * 2 + 1];
      samples[i] = ((high << 8) | low).toSigned(16);
    }
    return samples;
  } on PlatformException {
    return null;
  }
}

/// Play one decoded frame.
Future<void> playFrame(Int16List pcm) async {
  if (!audioIsBuilt) return;
  try {
    await _channel.invokeMethod<bool>('play', {
      'pcm': pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes),
    });
  } on PlatformException {
    // A device that will not take a frame is one that is closing.
  }
}

/// Earpiece or speakerphone.
Future<void> useSpeaker(bool loud) async {
  if (!audioIsBuilt) return;
  try {
    await _channel.invokeMethod<bool>('route', {'speaker': loud});
  } on PlatformException {
    // Routing is a preference. A call that will not switch to the speaker is
    // still a call.
  }
}

/// How many captured frames were thrown away because nothing collected them.
///
/// Not an error count on its own. A handful over a long call is the ordinary
/// condition of a phone; a number that climbs steadily means the encode loop is
/// not keeping up, and that is worth showing somebody.
Future<int> droppedFrames() async {
  if (!audioIsBuilt) return 0;
  try {
    return await _channel.invokeMethod<int>('dropped') ?? 0;
  } on PlatformException {
    return 0;
  }
}

Future<void> stopAudio() async {
  if (!audioIsBuilt) return;
  try {
    await _channel.invokeMethod<void>('stop');
  } on PlatformException {
    // Already closed.
  }
}

/// The audio devices said no, with a reason a person can act on.
class AudioRefused implements Exception {
  const AudioRefused(this.message);
  final String message;
  @override
  String toString() => message;
}
