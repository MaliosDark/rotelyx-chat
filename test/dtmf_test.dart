/// The touch tones are the frequencies they claim to be.
///
/// Measured rather than eyeballed: a pair of sine waves looks right in any
/// plot and a wrong one is only wrong to a decoder. Each key is checked by
/// correlating the generated samples against the two frequencies it should
/// contain and against one it should not, which is the same thing a receiver
/// does and needs no library to do here.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/call_api.dart';
import 'package:rotelyx_chat/rotelyx/dtmf.dart';

/// How much of a signal sits at one frequency, by the Goertzel construction.
double energyAt(List<int> samples, double freq) {
  var real = 0.0;
  var imaginary = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final angle = 2 * math.pi * freq * i / callSampleRate;
    real += samples[i] * math.cos(angle);
    imaginary += samples[i] * math.sin(angle);
  }
  return math.sqrt(real * real + imaginary * imaginary) / samples.length;
}

void main() {
  test('every key carries its own two frequencies and no others', () {
    for (final row in keypad) {
      for (final key in row) {
        final samples = samplesFor(key)!;
        final (low, high) = frequenciesFor(key)!;

        final atLow = energyAt(samples, low);
        final atHigh = energyAt(samples, high);

        // A frequency belonging to no key, so it cannot be confused with a
        // neighbour that happens to share a row or a column.
        final atNothing = energyAt(samples, 1000);

        expect(atLow, greaterThan(atNothing * 10),
            reason: '$key is missing its row frequency $low');
        expect(atHigh, greaterThan(atNothing * 10),
            reason: '$key is missing its column frequency $high');
      }
    }
  });

  test('no two keys are the same pair', () {
    final seen = <String>{};
    for (final row in keypad) {
      for (final key in row) {
        final (low, high) = frequenciesFor(key)!;
        expect(seen.add('$low/$high'), isTrue,
            reason: '$key repeats a pair another key already uses');
      }
    }
  });

  test('a tone leaves room for the voice it is mixed into', () {
    // Mixed on top of speech that is already using the range, so a tone near
    // full scale makes the sum clip, and a clipped tone is broadband noise:
    // the one thing it must not become. See `_amplitude` in dtmf.dart.
    for (final row in keypad) {
      for (final key in row) {
        final peak = samplesFor(key)!
            .map((s) => s.abs())
            .reduce((a, b) => a > b ? a : b);
        expect(peak, lessThan(32767 * 0.35),
            reason: '$key peaks at $peak, too loud to sit under a voice');
      }
    }
  });

  test('it starts and ends at silence, so it does not click', () {
    final samples = samplesFor('5')!;
    expect(samples.first.abs(), lessThan(50));
    expect(samples.last.abs(), lessThan(50));
  });

  test('a key that is not one produces nothing rather than silence', () {
    expect(samplesFor('A'), isNull);
    expect(samplesFor(''), isNull);
    expect(frequenciesFor('!'), isNull);
  });
}
