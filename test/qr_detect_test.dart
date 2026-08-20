/// Proof that `lib/qr/detect.dart` finds a code in an image.
///
/// `qr_decode_test.dart` starts from a clean grid and checks the arithmetic.
/// This one starts from pixels, which is the problem the camera actually poses:
/// the code is somewhere in the frame, at some angle, at some size, under
/// imperfect light.
///
/// The frames are synthesised rather than photographed so the expected answer
/// is known exactly and the test needs no fixtures. Rotation, perspective,
/// uneven lighting, blur and sensor noise are each applied on purpose, because
/// each one is a way real scanning fails.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:rotelyx_chat/qr/decode.dart';
import 'package:rotelyx_chat/qr/detect.dart';

QrImage encode(String text, QrLevel level) {
  final code = QrCode.fromData(
    data: text,
    errorCorrectLevel: const [
      QrErrorCorrectLevel.L,
      QrErrorCorrectLevel.M,
      QrErrorCorrectLevel.Q,
      QrErrorCorrectLevel.H,
    ][level.index],
  );
  return QrImage(code);
}

/// A projective map from the unit square to a quadrilateral, and its inverse.
///
/// The renderer works backwards: for each pixel it asks which module it came
/// from. That is the inverse direction, so the map is built forwards and then
/// inverted through its adjugate.
class Homography {
  Homography(this.m);
  final List<double> m;

  factory Homography.toQuad(List<double> q) {
    final dx3 = q[0] - q[2] + q[4] - q[6];
    final dy3 = q[1] - q[3] + q[5] - q[7];
    if (dx3 == 0 && dy3 == 0) {
      return Homography([
        q[2] - q[0], q[4] - q[2], q[0], //
        q[3] - q[1], q[5] - q[3], q[1], //
        0, 0, 1,
      ]);
    }
    final dx1 = q[2] - q[4];
    final dx2 = q[6] - q[4];
    final dy1 = q[3] - q[5];
    final dy2 = q[7] - q[5];
    final den = dx1 * dy2 - dx2 * dy1;
    final a13 = (dx3 * dy2 - dx2 * dy3) / den;
    final a23 = (dx1 * dy3 - dx3 * dy1) / den;
    return Homography([
      q[2] - q[0] + a13 * q[2], q[6] - q[0] + a23 * q[6], q[0], //
      q[3] - q[1] + a13 * q[3], q[7] - q[1] + a23 * q[7], q[1], //
      a13, a23, 1,
    ]);
  }

  Homography get inverse {
    final a11 = m[0], a21 = m[1], a31 = m[2];
    final a12 = m[3], a22 = m[4], a32 = m[5];
    final a13 = m[6], a23 = m[7], a33 = m[8];
    return Homography([
      a22 * a33 - a23 * a32, a23 * a31 - a21 * a33, a21 * a32 - a22 * a31, //
      a13 * a32 - a12 * a33, a11 * a33 - a13 * a31, a12 * a31 - a11 * a32, //
      a12 * a23 - a13 * a22, a13 * a21 - a11 * a23, a11 * a22 - a12 * a21,
    ]);
  }

  Point<double> apply(double x, double y) {
    final w = m[6] * x + m[7] * y + m[8];
    return Point((m[0] * x + m[1] * y + m[2]) / w,
        (m[3] * x + m[4] * y + m[5]) / w);
  }
}

/// Draw a code into a frame, mapping the symbol onto an arbitrary quad.
///
/// [quad] is eight numbers, the pixel coordinates of the symbol's four corners
/// clockwise from top left, including the quiet zone. Everything outside is
/// paper.
Luma render(
  QrImage code, {
  required int width,
  required int height,
  required List<double> quad,
  int quiet = 4,
  double gradient = 0.0,
  double blur = 0.0,
  double noise = 0.0,
  int seed = 1,
}) {
  final span = code.moduleCount + 2 * quiet;
  final toPixels = Homography.toQuad(quad);
  final toModules = toPixels.inverse;
  final pixels = Uint8List(width * height)..fillRange(0, width * height, 235);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final at = toModules.apply(x + 0.5, y + 0.5);
      if (at.x < 0 || at.y < 0 || at.x >= 1 || at.y >= 1) continue;
      final col = (at.x * span).floor() - quiet;
      final row = (at.y * span).floor() - quiet;
      if (col < 0 || row < 0 || col >= code.moduleCount || row >= code.moduleCount) {
        continue;
      }
      pixels[y * width + x] = code.isDark(row, col) ? 25 : 235;
    }
  }

  if (blur > 0) {
    final copy = Uint8List.fromList(pixels);
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        var sum = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            sum += copy[(y + dy) * width + x + dx];
          }
        }
        final soft = sum / 9.0;
        final at = y * width + x;
        pixels[at] = (copy[at] * (1 - blur) + soft * blur).round().clamp(0, 255);
      }
    }
  }

  if (gradient > 0 || noise > 0) {
    final random = Random(seed);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final at = y * width + x;
        var v = pixels[at].toDouble();
        // A light source off to one side, which is what breaks a single global
        // brightness threshold.
        v *= 1.0 - gradient * (x / width);
        if (noise > 0) v += (random.nextDouble() - 0.5) * 2 * noise;
        pixels[at] = v.round().clamp(0, 255);
      }
    }
  }

  return Luma(width, height, pixels);
}

/// The symbol placed squarely in the frame, rotated by [degrees] about its
/// centre.
List<double> squareQuad(double centreX, double centreY, double size,
    {double degrees = 0}) {
  final r = degrees * pi / 180;
  final half = size / 2;
  Point<double> corner(double dx, double dy) => Point(
      centreX + (dx * cos(r) - dy * sin(r)) * half,
      centreY + (dx * sin(r) + dy * cos(r)) * half);
  final a = corner(-1, -1);
  final b = corner(1, -1);
  final c = corner(1, 1);
  final d = corner(-1, 1);
  return [a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y];
}

void main() {
  const payload = 'RTLX 7QK2WZ3M8XPT6VN4HJ5RYB9CDFG';

  test('reads a code sitting flat in the frame', () {
    final image = render(encode(payload, QrLevel.high),
        width: 400, height: 400, quad: squareQuad(200, 200, 300));
    expect(scan(image)?.text, payload);
  });

  test('reads a code at every rotation', () {
    final code = encode(payload, QrLevel.high);
    for (var degrees = 0; degrees < 360; degrees += 15) {
      final image = render(code,
          width: 420,
          height: 420,
          quad: squareQuad(210, 210, 280, degrees: degrees.toDouble()));
      expect(scan(image)?.text, payload, reason: 'failed at $degrees degrees');
    }
  });

  test('reads a code held at an angle', () {
    // The far edge genuinely shorter than the near one, which is what an
    // affine map cannot represent and the alignment square exists to fix.
    final code = encode(payload, QrLevel.high);
    final image = render(code,
        width: 460,
        height: 420,
        quad: [110, 60, 380, 110, 360, 330, 130, 380]);
    expect(scan(image)?.text, payload);
  });

  test('reads a code under a lighting gradient', () {
    final image = render(encode(payload, QrLevel.high),
        width: 400,
        height: 400,
        quad: squareQuad(200, 200, 300),
        gradient: 0.55);
    expect(scan(image)?.text, payload);
  });

  test('reads a blurred and noisy code', () {
    final image = render(encode(payload, QrLevel.high),
        width: 440,
        height: 440,
        quad: squareQuad(220, 220, 320, degrees: 7),
        blur: 0.7,
        noise: 14,
        gradient: 0.25);
    expect(scan(image)?.text, payload);
  });

  test('reads a code that is off centre and small', () {
    final image = render(encode(payload, QrLevel.high),
        width: 640, height: 480, quad: squareQuad(180, 150, 190, degrees: -12));
    expect(scan(image)?.text, payload);
  });

  test('reads every correction level', () {
    for (final level in QrLevel.values) {
      final image = render(encode(payload, level),
          width: 400, height: 400, quad: squareQuad(200, 200, 300));
      expect(scan(image)?.text, payload, reason: 'failed at ${level.name}');
    }
  });

  test('a frame with no code returns null instead of inventing one', () {
    final random = Random(3);
    for (var attempt = 0; attempt < 12; attempt++) {
      final pixels = Uint8List(320 * 240);
      for (var i = 0; i < pixels.length; i++) {
        pixels[i] = random.nextInt(256);
      }
      expect(scan(Luma(320, 240, pixels)), isNull);
    }
    final blank = Uint8List(320 * 240)..fillRange(0, 320 * 240, 200);
    expect(scan(Luma(320, 240, blank)), isNull);
  });

  test('colour frames reduce to brightness correctly', () {
    final mono = render(encode(payload, QrLevel.high),
        width: 400, height: 400, quad: squareQuad(200, 200, 300));
    final rgba = Uint8List(400 * 400 * 4);
    for (var i = 0; i < 400 * 400; i++) {
      final v = mono.pixels[i];
      rgba[i * 4] = v;
      rgba[i * 4 + 1] = v;
      rgba[i * 4 + 2] = v;
      rgba[i * 4 + 3] = 255;
    }
    expect(scan(Luma.fromRgba(400, 400, rgba))?.text, payload);
  });
}
