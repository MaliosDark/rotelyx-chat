/// What the picture codec has to be true of, measured rather than asserted.
///
/// A codec that round trips is not the claim. The claim is that a photograph
/// survives 64 KiB well enough to be worth sending, and the only way to say
/// that is with a number, so these measure the error and the size and fail if
/// either goes the wrong way.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/photo_codec.dart';

/// Something photograph shaped, made rather than loaded.
///
/// Smooth gradients, a few hard edges and a patch of noise, which between them
/// exercise the three things a picture codec is judged on: it must not band the
/// sky, it must not ring the edges, and it must not spend its whole budget on
/// grain.
Uint8List _photograph(int w, int h, {bool grain = true}) {
  final rgba = Uint8List(w * h * 4);
  final random = math.Random(7);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;

      // A sky, which is where banding shows.
      var r = 40 + 120 * y / h;
      var g = 90 + 110 * y / h;
      var b = 170 + 70 * y / h;

      // A horizon and a building, which is where ringing shows.
      if (y > h * 0.6) {
        r = 70 + 40 * math.sin(x / 9);
        g = 60 + 30 * math.cos(x / 13);
        b = 55;
      }
      if (x > w * 0.3 && x < w * 0.45 && y > h * 0.35) {
        r = 200;
        g = 195;
        b = 185;
      }

      // And grain, which must not be worth encoding.
      final speckle = grain ? (random.nextDouble() - 0.5) * 10 : 0.0;

      rgba[i] = (r + speckle).round().clamp(0, 255);
      rgba[i + 1] = (g + speckle).round().clamp(0, 255);
      rgba[i + 2] = (b + speckle).round().clamp(0, 255);
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

/// Peak signal to noise, in decibels.
///
/// A blunt measure and the standard one. Above 30 is ordinarily called
/// acceptable for a photograph, above 35 good, and the difference between 28
/// and 32 is the difference between a picture somebody complains about and one
/// they do not mention.
double _psnr(Uint8List a, Uint8List b) {
  var sum = 0.0;
  var n = 0;
  for (var i = 0; i < a.length; i += 4) {
    for (var c = 0; c < 3; c++) {
      final d = a[i + c] - b[i + c];
      sum += d * d;
      n++;
    }
  }
  final mse = sum / n;
  if (mse == 0) return 99;
  return 10 * (math.log(255 * 255 / mse) / math.ln10);
}

void main() {
  test('a picture comes back as the picture that went in', () {
    const w = 64;
    const h = 48;
    // Without grain, deliberately. The codec throws away speckle that nobody
    // can see, which is the right thing to do and would make this measurement
    // say something other than what it claims to.
    final original = _photograph(w, h, grain: false);

    final encoded = encodePhoto(original, w, h, quality: 95);
    final decoded = decodePhoto(encoded);

    expect(decoded, isNotNull);
    expect(decoded!.width, w);
    expect(decoded.height, h);
    expect(decoded.rgba.length, original.length);

    // Thirty is the floor here rather than forty, and the reason is colour
    // rather than the codec. Chroma is kept at half resolution, so the hard
    // colour edges in this test picture bleed by a pixel, and on a picture this
    // small that is most of the measured error. The test below pins the part
    // that is not colour.
    expect(_psnr(original, decoded.rgba), greaterThan(30));
  });

  test('brightness survives almost untouched', () {
    // The same measurement with colour taken out of it, which is what says
    // whether the transform, the quantiser and the arithmetic coder are doing
    // their job. Chroma subsampling is a deliberate loss and this is the number
    // it would otherwise hide.
    const w = 64;
    const h = 48;
    final grey = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final v = (30 + 200 * y / h).round().clamp(0, 255);
        grey[i] = v;
        grey[i + 1] = v;
        grey[i + 2] = v;
        grey[i + 3] = 255;
      }
    }

    final decoded = decodePhoto(encodePhoto(grey, w, h, quality: 95))!;
    expect(_psnr(grey, decoded.rgba), greaterThan(50));
  });

  test('a photograph fits the free tier and is still a photograph', () {
    // Roughly what a phone camera gives after the first shrink, and the size
    // this has to work at.
    const w = 1024;
    const h = 768;
    final original = _photograph(w, h);

    const budget = 64 * 1024;
    Uint8List? best;
    var bestQuality = 0;

    for (final quality in const [90, 80, 70, 60, 50, 40, 30, 20]) {
      final encoded = encodePhoto(original, w, h, quality: quality);
      if (encoded.length <= budget) {
        best = encoded;
        bestQuality = quality;
        break;
      }
    }

    expect(best, isNotNull,
        reason: 'a 1024 by 768 photograph should fit 64 KiB somewhere');

    final decoded = decodePhoto(best!);
    expect(decoded, isNotNull);

    final psnr = _psnr(original, decoded!.rgba);
    // ignore: avoid_print
    print('1024x768 at quality $bestQuality: '
        '${best.length ~/ 1024} KiB, ${psnr.toStringAsFixed(1)} dB, '
        '${(best.length * 8 / (w * h)).toStringAsFixed(2)} bits per pixel');

    expect(psnr, greaterThan(28),
        reason: 'a photograph at 64 KiB has to still look like one');
  });

  test('bytes that are not ours are refused rather than misread', () {
    expect(isRotelyxPhoto(Uint8List.fromList([1, 2, 3])), isFalse);
    expect(decodePhoto(Uint8List.fromList(List.filled(64, 9))), isNull);
  });

  test('lower quality is smaller, in every step', () {
    const w = 256;
    const h = 192;
    final original = _photograph(w, h);

    var previous = 1 << 30;
    for (final quality in const [90, 70, 50, 30, 10]) {
      final size = encodePhoto(original, w, h, quality: quality).length;
      expect(size, lessThan(previous),
          reason: 'quality $quality should be smaller than the step above it');
      previous = size;
    }
  });
}
