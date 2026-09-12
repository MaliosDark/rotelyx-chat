/// What the animation encoder has to be true of, measured rather than claimed.
///
/// The claim is not that it round trips. It is that a reaction GIF fits one
/// envelope and is still moving when it gets there, so these check the size,
/// the frame count, and that what comes out is a file a decoder accepts.
library;

import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/gif_codec.dart';

/// A frame of something animation shaped: a coloured disc on a gradient.
///
/// A disc rather than noise, because what a palette has to cope with is areas
/// of flat colour meeting a curve, which is what cartoons and captions are.
GifFrame _frame(int w, int h, int step, {int steps = 12}) {
  final rgba = Uint8List(w * h * 4);
  final cx = w * (0.25 + 0.5 * step / steps);
  final cy = h * 0.5;
  final r = w * 0.18;

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      var red = 30 + 90 * y ~/ h;
      var green = 40 + 60 * x ~/ w;
      var blue = 120;

      final dx = x - cx;
      final dy = y - cy;
      if (dx * dx + dy * dy < r * r) {
        red = 240;
        green = 90 + 120 * step ~/ steps;
        blue = 40;
      }

      rgba[i] = red;
      rgba[i + 1] = green;
      rgba[i + 2] = blue;
      rgba[i + 3] = 255;
    }
  }
  return GifFrame(
    rgba: rgba,
    width: w,
    height: h,
    delay: const Duration(milliseconds: 80),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a header is read rather than trusted', () {
    final gif = encodeGif([_frame(16, 16, 0), _frame(16, 16, 1)]);
    expect(isGif(gif), isTrue);
    expect(isGif(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0])), isFalse);
    expect(isGif(Uint8List.fromList([1, 2, 3])), isFalse);
  });

  test('what comes out is a file a decoder accepts, and it moves', () async {
    final frames = [for (var i = 0; i < 8; i++) _frame(120, 90, i, steps: 8)];
    final gif = encodeGif(frames);

    final codec = await ui.instantiateImageCodec(gif);
    expect(codec.frameCount, 8, reason: 'every frame should have survived');

    final first = await codec.getNextFrame();
    expect(first.image.width, 120);
    expect(first.image.height, 90);
    expect(first.duration.inMilliseconds, greaterThan(0),
        reason: 'a frame with no delay is one every player times differently');
    first.image.dispose();
  });

  test('a reaction animation fits one free envelope', () async {
    // The rung `fitAnimation` lands a reaction GIF on, and 44 KiB is what one
    // envelope holds without a capability token.
    //
    // The whole ladder is printed rather than only this rung, because these
    // numbers are what the ladder in `fitAnimation` was chosen from and a
    // change in the encoder that moves them should be visible here rather
    // than discovered on a phone.
    for (final (n, edge, colours) in const [
      (12, 320, 128),
      (12, 240, 96),
      (8, 200, 64),
      (6, 160, 48),
    ]) {
      final h = (edge * 0.75).round();
      final size =
          encodeGif([for (var i = 0; i < n; i++) _frame(edge, h, i, steps: n)],
                  colours: colours)
              .length;
      // ignore: avoid_print
      print('$n frames, ${edge}x$h, $colours colours: '
          '${(size / 1024).toStringAsFixed(1)} KiB');
    }

    final frames = [for (var i = 0; i < 8; i++) _frame(200, 150, i, steps: 8)];
    final gif = encodeGif(frames, colours: 64);
    expect(gif.length, lessThanOrEqualTo(44 * 1024),
        reason: 'a reaction animation has to fit one free envelope');

    final codec = await ui.instantiateImageCodec(gif);
    expect(codec.frameCount, 8);
  });

  test('fewer colours is a smaller file', () {
    final frames = [for (var i = 0; i < 6; i++) _frame(160, 120, i, steps: 6)];
    var previous = 1 << 30;
    for (final colours in const [256, 128, 64, 32]) {
      final size = encodeGif(frames, colours: colours).length;
      expect(size, lessThan(previous),
          reason: '$colours colours should be smaller than the step above');
      previous = size;
    }
  });

  test('an animation of nothing is refused rather than produced', () {
    expect(encodeGif(const []), isEmpty);
  });
}
