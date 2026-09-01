/// The touch tones, generated rather than recorded.
///
/// # What this is for, and what it is not
///
/// A keypad during a call sends the tones a telephone sends: two sine waves at
/// once, one from a row and one from a column, which is what makes them
/// recognisable to a machine and impossible to produce by accident with a
/// voice.
///
/// They are mixed into the outgoing audio, in band, so the other person hears
/// them. That is the honest description of what this does today, because there
/// is nothing else on the far side to hear them: a call here is between two
/// people, not between a person and a telephone exchange.
///
/// Telephony sends these out of band instead, as RFC 2833 events, precisely
/// because a speech codec is built to carry a voice and treats a pair of pure
/// tones as something to be approximated. Ours does the same, so a tone that
/// arrives is audible but is not guaranteed to survive well enough for a
/// machine to decode it. When there is a gateway to decode for, the exchange
/// belongs in `FrameKind::CallControl`, which exists in the wire format and
/// carries nothing yet.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'call_api.dart';

/// The row and column frequencies, in hertz, from the original specification.
const _rows = <int, double>{0: 697, 1: 770, 2: 852, 3: 941};
const _columns = <int, double>{0: 1209, 1: 1336, 2: 1477, 3: 1633};

/// The keypad, laid out as it is on a telephone.
const keypad = <List<String>>[
  ['1', '2', '3'],
  ['4', '5', '6'],
  ['7', '8', '9'],
  ['*', '0', '#'],
];

/// How long one press sounds.
///
/// 160 ms. The specification's floor for a tone a receiver must accept is 40,
/// and telephones send about 100; longer is easier to hear over a connection
/// that is dropping frames, and short enough that holding a conversation
/// through a menu does not become slow.
const toneMilliseconds = 160;

/// Amplitude, well under full scale.
///
/// A quarter. These are pure tones, which sound far louder than speech at the
/// same peak, and they are mixed on top of a voice that is already using the
/// range: at full scale the sum clips, and a clipped tone is broadband noise,
/// which is the one thing it must not turn into.
const _amplitude = 0.25;

/// The two frequencies for a key, or nothing if it is not one.
(double, double)? frequenciesFor(String key) {
  for (var r = 0; r < keypad.length; r++) {
    final c = keypad[r].indexOf(key);
    if (c >= 0) return (_rows[r]!, _columns[c]!);
  }
  return null;
}

/// One key press, as samples at [callSampleRate].
///
/// Faded in and out over five milliseconds. A tone that starts at full
/// amplitude in one sample steps the waveform, and a step is a click that
/// carries across the whole spectrum: audible at both ends and, at the far
/// end, the sort of thing a decoder spends bits on.
Int16List? samplesFor(String key) {
  final pair = frequenciesFor(key);
  if (pair == null) return null;
  final (low, high) = pair;

  const total = callSampleRate * toneMilliseconds ~/ 1000;
  const fade = callSampleRate * 5 ~/ 1000;
  final out = Int16List(total);

  for (var i = 0; i < total; i++) {
    final t = i / callSampleRate;
    final value = math.sin(2 * math.pi * low * t) +
        math.sin(2 * math.pi * high * t);

    var envelope = 1.0;
    if (i < fade) envelope = i / fade;
    if (i > total - fade) envelope = (total - i) / fade;

    out[i] = (value / 2 * _amplitude * envelope * 32767).round();
  }

  return out;
}
