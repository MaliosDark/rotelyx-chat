// A profile picture has to arrive, and arriving means fitting in an envelope.
//
// The free tier carries 64 KiB per envelope and the picture travels as base64
// inside a signal. A 256 pixel PNG of a photograph is two to three times that,
// and for as long as that was what went on the wire, a face chosen in settings
// was refused by the mailbox and shown on nobody's phone. What is tested here
// is the bound, on the worst picture there is: noise, which no codec squeezes.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/photo_codec.dart';

void main() {
  test('the worst 256 pixel picture still fits the wire budget', () {
    final rng = Random(7);
    final rgba = Uint8List(256 * 256 * 4);
    for (var i = 0; i < rgba.length; i++) {
      rgba[i] = (i % 4 == 3) ? 255 : rng.nextInt(256);
    }
    final wire = encodeProfileForTheWire(rgba, 256, 256);
    expect(wire, isNotNull, reason: 'noise at 256 pixels must still encode');
    expect(wire!.length, lessThanOrEqualTo(profileWireBytes));
    // And base64 of it, which is what the signal carries, under the envelope.
    expect((wire.length * 4 / 3).ceil(), lessThan(64 * 1024 - 8 * 1024));
    expect(isRotelyxPhoto(wire), isTrue);
    final back = decodePhoto(wire);
    expect(back, isNotNull);
    expect(back!.width, 256);
    expect(back.height, 256);
  });

  test('a real face is small and still a face', () {
    // A smooth gradient with a dark circle: what a photograph of a person
    // encodes like, far from noise.
    final rgba = Uint8List(256 * 256 * 4);
    for (var y = 0; y < 256; y++) {
      for (var x = 0; x < 256; x++) {
        final i = (y * 256 + x) * 4;
        final inside = (x - 128) * (x - 128) + (y - 128) * (y - 128) < 80 * 80;
        rgba[i] = inside ? 90 : (200 + x ~/ 8);
        rgba[i + 1] = inside ? 60 : (180 + y ~/ 8);
        rgba[i + 2] = inside ? 40 : 220;
        rgba[i + 3] = 255;
      }
    }
    final wire = encodeProfileForTheWire(rgba, 256, 256)!;
    expect(wire.length, lessThan(12 * 1024));
    final back = decodePhoto(wire)!;
    // The centre is still dark and the corner still light.
    final centre = ((128 * 256) + 128) * 4;
    final corner = ((4 * 256) + 4) * 4;
    expect(back.rgba[centre], lessThan(130));
    expect(back.rgba[corner], greaterThan(160));
  });
}
