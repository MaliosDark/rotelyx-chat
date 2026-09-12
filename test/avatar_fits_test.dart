/// A photograph can be somebody's picture.
///
/// The defect this exists for: an avatar was re-encoded as PNG, because
/// `toByteData` offers PNG and raw pixels and nothing else, and a photograph
/// at 256 square is well over the 96 KiB an avatar is allowed. So choosing a
/// face off a camera roll was refused with a message telling somebody to find
/// a smaller photograph, which nobody has.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/gif_codec.dart';

/// Something face shaped: skin over a background, with shading and grain.
///
/// Grain matters here. It is what makes a photograph incompressible as PNG
/// and it is the whole reason the old path failed.
GifFrame _face(int side) {
  final rgba = Uint8List(side * side * 4);
  final random = math.Random(11);

  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final i = (y * side + x) * 4;

      // A background with a gradient.
      var r = 60 + 40 * x ~/ side;
      var g = 70 + 30 * y ~/ side;
      var b = 90;

      // An oval of skin, shaded from one side.
      final dx = (x - side / 2) / (side * 0.30);
      final dy = (y - side * 0.52) / (side * 0.38);
      if (dx * dx + dy * dy < 1) {
        final shade = 1.0 - 0.35 * ((x / side) - 0.3).abs();
        r = (214 * shade).round();
        g = (172 * shade).round();
        b = (146 * shade).round();
      }

      final grain = (random.nextDouble() - 0.5) * 14;
      rgba[i] = (r + grain).round().clamp(0, 255);
      rgba[i + 1] = (g + grain).round().clamp(0, 255);
      rgba[i + 2] = (b + grain).round().clamp(0, 255);
      rgba[i + 3] = 255;
    }
  }
  return GifFrame(
    rgba: rgba,
    width: side,
    height: side,
    delay: const Duration(milliseconds: 100),
  );
}

void main() {
  const side = 256;
  const budget = 96 * 1024;

  test('a photographic face fits what an avatar is allowed', () {
    final face = _face(side);

    for (final colours in const [256, 192, 128, 64]) {
      final encoded = encodeGif([face], colours: colours);
      // ignore: avoid_print
      print('256x256 face, $colours colours: '
          '${(encoded.length / 1024).toStringAsFixed(1)} KiB');
    }

    // The first rung the avatar path tries after PNG, which is the one it
    // should land on.
    final best = encodeGif([face], colours: 256);
    expect(best.length, lessThanOrEqualTo(budget),
        reason: 'a face at full palette has to fit, or the fallback is no '
            'better than the PNG it replaces');
  });

  test('one frame is a still, and a decoder takes it', () async {
    final encoded = encodeGif([_face(side)], colours: 192);
    expect(isGif(encoded), isTrue);

    // Drawn by `Image.memory` on every platform, including a build that
    // predates any of this, which is why the fallback is a GIF rather than
    // this application's own codec.
    final codec = await instantiateImageCodecForTest(encoded);
    expect(codec, 1);
  });
}

/// How many frames a decoder finds. Kept small so the test above reads as one
/// assertion rather than as four lines of codec handling.
Future<int> instantiateImageCodecForTest(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return codec.frameCount;
}
