/// The last link in the chain: pixels the application actually painted.
///
/// Every other test here builds a symbol in memory. That proves the arithmetic
/// and it proves the detector, but it does not prove the *drawing*, and the
/// drawing is where a logo in a QR code usually goes wrong. The plate creeps a
/// few percent wider, the correction level gets left on the encoder's default,
/// the module colour softens to match the theme, and the result still looks
/// like a QR code in every mockup while scanning badly in every hand.
///
/// So this test starts from a screenshot of the running application, taken from
/// a release build in a real browser by `tool/e2e/shots.py`, and reads it with
/// the same decoder the camera uses.
///
/// If it fails, the code the app is showing people cannot be scanned.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/qr/decode.dart';
import 'package:rotelyx_chat/qr/detect.dart';
import 'package:rotelyx_chat/rotelyx/meeting_code.dart';

void main() {
  test('the code the application draws can be read back', () {
    final file = File('test/fixtures/rendered-pair-screen.gray');
    expect(file.existsSync(), isTrue,
        reason: 'fixture missing, regenerate with tool/e2e/shots.py');

    const width = 520;
    const height = 460;
    final pixels = file.readAsBytesSync();
    expect(pixels.length, width * height);

    final result = scan(Luma(width, height, pixels));

    expect(result, isNotNull,
        reason: 'the pairing screen is showing a code nothing can scan');
    expect(result!.text, 'RTLX1VR3ACHNMDPM4V7LPYUF35HK6');

    // And it is a meeting code, not merely some readable string.
    expect(readMeetingCode(result.text), result.text);

    // Drawn at the highest correction level, which is what pays for the logo.
    expect(result.level, QrLevel.high);
    expect(result.version, 4);
  });
}
