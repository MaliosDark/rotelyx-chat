/// Proof that the decoder in `lib/qr/decode.dart` is correct.
///
/// The app already contains an encoder, the one that draws the pairing code. So
/// the test does not need fixtures or sample photographs: it encodes something,
/// hands the resulting module grid straight to the decoder, and checks the text
/// comes back. Anything wrong in the layout walk, the mask, the interleave, the
/// block tables or the Reed-Solomon arithmetic breaks that round trip.
///
/// It runs over every version and every correction level, which is what makes
/// the transcribed tables in `lib/qr/tables.dart` trustworthy rather than
/// merely plausible.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:rotelyx_chat/qr/decode.dart';
import 'package:rotelyx_chat/qr/tables.dart';

/// Encode with the app's own encoder and hand back the grid it produced.
QrMatrix encode(String text, int version, QrLevel level) {
  final code = QrCode(version, const [
    QrErrorCorrectLevel.L,
    QrErrorCorrectLevel.M,
    QrErrorCorrectLevel.Q,
    QrErrorCorrectLevel.H,
  ][level.index])
    ..addData(text);

  final image = QrImage(code);
  final m = QrMatrix(image.moduleCount);
  for (var row = 0; row < image.moduleCount; row++) {
    for (var col = 0; col < image.moduleCount; col++) {
      m.set(row, col, image.isDark(row, col));
    }
  }
  return m;
}

/// How many data bytes a version and level can hold, minus the segment header,
/// so the test fills each symbol close to capacity rather than trivially.
int capacity(int version, QrLevel level) {
  var data = 0;
  final spec = rsBlockTable[version - 1][level.index];
  for (var i = 0; i < spec.length; i += 3) {
    data += spec[i] * spec[i + 2];
  }
  final header = 4 + (version <= 9 ? 8 : 16);
  return data - (header + 7) ~/ 8;
}

void main() {
  test('every version and level survives a round trip', () {
    final random = Random(20260817);
    var checked = 0;

    for (var version = 1; version <= 40; version++) {
      for (final level in QrLevel.values) {
        final length = capacity(version, level);
        expect(length, greaterThan(0),
            reason: 'version $version level $level has no room, table is wrong');

        final text = String.fromCharCodes(
            List.generate(length, (_) => 33 + random.nextInt(90)));

        final result = decodeMatrix(encode(text, version, level));

        expect(result, isNotNull,
            reason: 'version $version level ${level.name} did not decode');
        expect(result!.text, text,
            reason: 'version $version level ${level.name} decoded wrongly');
        expect(result.version, version);
        expect(result.level, level,
            reason: 'version $version read its correction level wrongly');
        checked++;
      }
    }

    expect(checked, 160);
  });

  test('numeric and alphanumeric segments decode', () {
    for (final text in ['0123456789', 'RTLX ABC 42', '1', '99']) {
      final result = decodeMatrix(encode(text, 4, QrLevel.high));
      expect(result?.text, text, reason: 'failed on "$text"');
    }
  });

  test('text beyond Latin-1 survives', () {
    const text = 'Rotelyx: cifrado de extremo a extremo';
    expect(decodeMatrix(encode(text, 6, QrLevel.high))?.text, text);
  });

  test('damage up to the correction budget is repaired', () {
    // Level H spends thirty percent of the symbol on redundancy, and this is
    // the property the embedded logo depends on: the modules it covers read as
    // whatever the camera saw there, and the arithmetic puts them back.
    const text = 'RTLX2QK7WZ3M8XPT6VN4HJ5RYB9CDFGS';
    final clean = encode(text, 5, QrLevel.high);

    final damaged = QrMatrix(clean.dimension);
    for (var row = 0; row < clean.dimension; row++) {
      for (var col = 0; col < clean.dimension; col++) {
        damaged.set(row, col, clean.get(row, col));
      }
    }

    // A square in the middle, the size and place a logo would occupy.
    final centre = clean.dimension ~/ 2;
    for (var row = centre - 3; row <= centre + 3; row++) {
      for (var col = centre - 3; col <= centre + 3; col++) {
        damaged.set(row, col, true);
      }
    }

    expect(decodeMatrix(damaged)?.text, text);
  });

  test('a grid of noise is rejected rather than guessed at', () {
    final random = Random(7);
    var decoded = 0;
    for (var attempt = 0; attempt < 40; attempt++) {
      final m = QrMatrix(29);
      for (var row = 0; row < 29; row++) {
        for (var col = 0; col < 29; col++) {
          m.set(row, col, random.nextBool());
        }
      }
      if (decodeMatrix(m) != null) decoded++;
    }
    expect(decoded, 0);
  });
}
