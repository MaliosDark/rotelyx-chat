/// Finding a QR symbol inside a camera frame.
///
/// `decode.dart` starts from a clean grid of modules. Getting that grid out of
/// a photograph is the harder half, and it is a different kind of problem:
/// the symbol is somewhere in the frame, at some angle, under some lighting,
/// at a size nobody told us.
///
/// Four steps, in order:
///
///   1. **Binarise.** Decide, per pixel, dark or light. A single brightness
///      threshold for the whole frame fails the moment one side is in shadow,
///      so the threshold is computed per eight-by-eight block from that block's
///      own neighbourhood.
///   2. **Find the three corners.** Every QR symbol carries three identical
///      squares, one in each corner but the fourth. Their defining property is
///      a run of dark, light, dark, light, dark in the ratio 1:1:3:1:1, and
///      that ratio holds along any line through the centre, at any rotation.
///      That is what makes them findable without knowing the orientation.
///   3. **Work out the geometry.** Three corners give the size, the rotation
///      and the module pitch. The fourth corner is where a camera held at an
///      angle bends the square into a trapezium, so the nearest alignment
///      square is located and used to pin it down.
///   4. **Sample.** Walk the module grid, map each centre through the
///      resulting perspective transform, and read the pixel it lands on.
///
/// Steps two through four are the classic approach from the ZXing project,
/// which is the shape every scanner uses because it is the one that works.
library;

import 'dart:math';
import 'dart:typed_data';

import 'decode.dart';

/// A frame reduced to one brightness byte per pixel.
///
/// Colour is discarded before anything else happens. A QR code is defined in
/// black and white, and keeping three channels would triple the work of every
/// step below for no gain.
class Luma {
  Luma(this.width, this.height, this.pixels)
      : assert(pixels.length >= width * height);

  final int width;
  final int height;
  final Uint8List pixels;

  /// Build from the RGBA bytes a canvas hands back.
  ///
  /// The weights are the usual perceptual ones: the eye is far more sensitive
  /// to green than to blue, so a naive average would wash out exactly the
  /// contrast this needs.
  factory Luma.fromRgba(int width, int height, Uint8List rgba) {
    final out = Uint8List(width * height);
    for (var i = 0, p = 0; i < out.length; i++, p += 4) {
      out[i] = (rgba[p] * 77 + rgba[p + 1] * 150 + rgba[p + 2] * 29) >> 8;
    }
    return Luma(width, height, out);
  }
}

/// The binarised frame: one bit per pixel, true for dark.
class _Bin {
  _Bin(this.width, this.height) : bits = Uint8List(width * height);
  final int width;
  final int height;
  final Uint8List bits;

  bool get(int x, int y) =>
      x >= 0 && y >= 0 && x < width && y < height && bits[y * width + x] != 0;
}

const _block = 8;

/// Threshold each block against the average of its neighbours.
///
/// A block whose own brightest and darkest pixels are close together contains
/// no edge, so it is all paper or all ink. Thresholding it against itself would
/// turn film grain into a checkerboard, so such a block inherits its
/// neighbours' threshold instead.
_Bin _binarise(Luma image) {
  final w = image.width;
  final h = image.height;
  final out = _Bin(w, h);

  if (w < _block || h < _block) {
    // Too small for blocks to mean anything. One global threshold it is.
    var sum = 0;
    for (final p in image.pixels) {
      sum += p;
    }
    final threshold = sum ~/ max(1, w * h);
    for (var i = 0; i < w * h; i++) {
      out.bits[i] = image.pixels[i] < threshold ? 1 : 0;
    }
    return out;
  }

  final across = (w + _block - 1) ~/ _block;
  final down = (h + _block - 1) ~/ _block;
  final levels = Uint8List(across * down);

  for (var by = 0; by < down; by++) {
    final y0 = min(by * _block, h - _block);
    for (var bx = 0; bx < across; bx++) {
      final x0 = min(bx * _block, w - _block);

      var sum = 0;
      var lowest = 255;
      var highest = 0;
      for (var y = 0; y < _block; y++) {
        var at = (y0 + y) * w + x0;
        for (var x = 0; x < _block; x++, at++) {
          final v = image.pixels[at];
          sum += v;
          if (v < lowest) lowest = v;
          if (v > highest) highest = v;
        }
      }

      var level = sum ~/ (_block * _block);
      if (highest - lowest <= 24) {
        // No edge here. Assume paper, and defer to what is around it.
        level = lowest ~/ 2;
        if (by > 0 && bx > 0) {
          final around = (levels[(by - 1) * across + bx] +
                  2 * levels[by * across + bx - 1] +
                  levels[(by - 1) * across + bx - 1]) ~/
              4;
          if (lowest < around) level = around;
        }
      }
      levels[by * across + bx] = level;
    }
  }

  for (var by = 0; by < down; by++) {
    final y0 = min(by * _block, h - _block);
    for (var bx = 0; bx < across; bx++) {
      final x0 = min(bx * _block, w - _block);

      // Average over a five-by-five window of blocks, so the threshold moves
      // smoothly across the frame instead of stepping at block boundaries.
      final left = min(max(bx, 2), across - 3);
      final top = min(max(by, 2), down - 3);
      var sum = 0;
      for (var dy = -2; dy <= 2; dy++) {
        final row = (top + dy) * across;
        for (var dx = -2; dx <= 2; dx++) {
          sum += levels[row + left + dx];
        }
      }
      final threshold = sum ~/ 25;

      for (var y = 0; y < _block; y++) {
        var at = (y0 + y) * w + x0;
        for (var x = 0; x < _block; x++, at++) {
          out.bits[at] = image.pixels[at] <= threshold ? 1 : 0;
        }
      }
    }
  }

  return out;
}

// -----------------------------------------------------------------------------
// The three corner squares
// -----------------------------------------------------------------------------

class _Corner {
  _Corner(this.x, this.y, this.size);
  double x;
  double y;
  double size;

  /// How many scan lines have landed on this square.
  ///
  /// A frame with clutter in it turns up more candidates than the three a
  /// symbol has, and the count is how the real ones are told from the strays.
  int seen = 1;

  /// Whether a new sighting is the same square as this one.
  bool sameAs(double atX, double atY, double atSize) {
    if ((atY - y).abs() > size || (atX - x).abs() > size) return false;
    final drift = (atSize - size).abs();
    return drift <= 1.0 || drift <= size;
  }

  /// Fold a new sighting in, so repeated hits on the same square sharpen the
  /// estimate rather than producing duplicates.
  void absorb(double atX, double atY, double atSize) {
    final n = seen + 1;
    x = (seen * x + atX) / n;
    y = (seen * y + atY) / n;
    size = (seen * size + atSize) / n;
    seen = n;
  }
}

/// Does this run of five lengths hold the 1:1:3:1:1 ratio?
bool _isCorner(List<int> runs) {
  var total = 0;
  for (final r in runs) {
    if (r == 0) return false;
    total += r;
  }
  if (total < 7) return false;

  final unit = total / 7.0;
  final slack = unit / 2.0;
  return (unit - runs[0]).abs() < slack &&
      (unit - runs[1]).abs() < slack &&
      (3 * unit - runs[2]).abs() < 3 * slack &&
      (unit - runs[3]).abs() < slack &&
      (unit - runs[4]).abs() < slack;
}

double _centreOf(List<int> runs, int end) =>
    (end - runs[4] - runs[3]) - runs[2] / 2.0;

/// Re-measure the ratio along a line at right angles to the one that found it.
///
/// A row of text or a barcode can accidentally produce 1:1:3:1:1 horizontally.
/// Requiring the same ratio vertically, and then again diagonally, is what
/// separates a real corner square from a coincidence.
double _crossVertical(_Bin img, int fromY, int atX, int maxRun, int wanted) {
  final runs = List<int>.filled(5, 0);
  var y = fromY;

  while (y >= 0 && img.get(atX, y)) {
    runs[2]++;
    y--;
  }
  if (y < 0) return double.nan;
  while (y >= 0 && !img.get(atX, y) && runs[1] <= maxRun) {
    runs[1]++;
    y--;
  }
  if (y < 0 || runs[1] > maxRun) return double.nan;
  while (y >= 0 && img.get(atX, y) && runs[0] <= maxRun) {
    runs[0]++;
    y--;
  }
  if (runs[0] > maxRun) return double.nan;

  y = fromY + 1;
  while (y < img.height && img.get(atX, y)) {
    runs[2]++;
    y++;
  }
  if (y == img.height) return double.nan;
  while (y < img.height && !img.get(atX, y) && runs[3] < maxRun) {
    runs[3]++;
    y++;
  }
  if (y == img.height || runs[3] >= maxRun) return double.nan;
  while (y < img.height && img.get(atX, y) && runs[4] < maxRun) {
    runs[4]++;
    y++;
  }
  if (runs[4] >= maxRun) return double.nan;

  final total = runs.reduce((a, b) => a + b);
  if (5 * (total - wanted).abs() >= 2 * wanted) return double.nan;

  return _isCorner(runs) ? _centreOf(runs, y) : double.nan;
}

double _crossHorizontal(_Bin img, int fromX, int atY, int maxRun, int wanted) {
  final runs = List<int>.filled(5, 0);
  var x = fromX;

  while (x >= 0 && img.get(x, atY)) {
    runs[2]++;
    x--;
  }
  if (x < 0) return double.nan;
  while (x >= 0 && !img.get(x, atY) && runs[1] <= maxRun) {
    runs[1]++;
    x--;
  }
  if (x < 0 || runs[1] > maxRun) return double.nan;
  while (x >= 0 && img.get(x, atY) && runs[0] <= maxRun) {
    runs[0]++;
    x--;
  }
  if (runs[0] > maxRun) return double.nan;

  x = fromX + 1;
  while (x < img.width && img.get(x, atY)) {
    runs[2]++;
    x++;
  }
  if (x == img.width) return double.nan;
  while (x < img.width && !img.get(x, atY) && runs[3] < maxRun) {
    runs[3]++;
    x++;
  }
  if (x == img.width || runs[3] >= maxRun) return double.nan;
  while (x < img.width && img.get(x, atY) && runs[4] < maxRun) {
    runs[4]++;
    x++;
  }
  if (runs[4] >= maxRun) return double.nan;

  final total = runs.reduce((a, b) => a + b);
  if (5 * (total - wanted).abs() >= 2 * wanted) return double.nan;

  return _isCorner(runs) ? _centreOf(runs, x) : double.nan;
}

bool _crossDiagonal(_Bin img, int atX, int atY) {
  final runs = List<int>.filled(5, 0);

  var step = 0;
  while (atX >= step && atY >= step && img.get(atX - step, atY - step)) {
    runs[2]++;
    step++;
  }
  while (atX >= step && atY >= step && !img.get(atX - step, atY - step)) {
    runs[1]++;
    step++;
  }
  while (atX >= step && atY >= step && img.get(atX - step, atY - step)) {
    runs[0]++;
    step++;
  }

  step = 1;
  while (atX + step < img.width &&
      atY + step < img.height &&
      img.get(atX + step, atY + step)) {
    runs[2]++;
    step++;
  }
  while (atX + step < img.width &&
      atY + step < img.height &&
      !img.get(atX + step, atY + step)) {
    runs[3]++;
    step++;
  }
  while (atX + step < img.width &&
      atY + step < img.height &&
      img.get(atX + step, atY + step)) {
    runs[4]++;
    step++;
  }

  return _isCorner(runs);
}

/// Sweep the frame for corner squares.
List<_Corner> _findCorners(_Bin img) {
  final found = <_Corner>[];
  // Sampling every third row is enough: a corner square is at least seven
  // modules tall, and a symbol too small for that is too small to decode.
  final step = max(1, img.height ~/ 240) * 3;

  final runs = List<int>.filled(5, 0);

  for (var y = step - 1; y < img.height; y += step) {
    runs.fillRange(0, 5, 0);
    var state = 0;

    for (var x = 0; x < img.width; x++) {
      if (img.get(x, y)) {
        if (state.isOdd) state++;
        runs[state]++;
      } else {
        if (state.isEven) {
          if (state == 4) {
            if (_isCorner(runs)) {
              _consider(img, found, runs, y, x);
              runs.fillRange(0, 5, 0);
              state = 0;
            } else {
              // Not a corner, but the last two runs may start the next one.
              runs[0] = runs[2];
              runs[1] = runs[3];
              runs[2] = runs[4];
              runs[3] = 1;
              runs[4] = 0;
              state = 3;
            }
          } else {
            runs[++state]++;
          }
        } else {
          runs[state]++;
        }
      }
    }

    if (state == 4 && _isCorner(runs)) {
      _consider(img, found, runs, y, img.width);
    }
  }

  return found;
}

void _consider(_Bin img, List<_Corner> found, List<int> runs, int y, int endX) {
  final total = runs.reduce((a, b) => a + b);
  var centreX = _centreOf(runs, endX);

  final centreY = _crossVertical(img, y, centreX.round(), runs[2], total);
  if (centreY.isNaN) return;

  centreX = _crossHorizontal(img, centreX.round(), centreY.round(), runs[2], total);
  if (centreX.isNaN) return;

  if (!_crossDiagonal(img, centreX.round(), centreY.round())) return;

  final size = total / 7.0;
  for (final c in found) {
    if (c.sameAs(centreX, centreY, size)) {
      c.absorb(centreX, centreY, size);
      return;
    }
  }
  found.add(_Corner(centreX, centreY, size));
}

// -----------------------------------------------------------------------------
// Geometry
// -----------------------------------------------------------------------------

double _distance(_Corner a, _Corner b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return sqrt(dx * dx + dy * dy);
}

/// Work out which of three corner squares is which.
///
/// The two furthest apart are the ends of the diagonal, so the remaining one is
/// the corner they both touch, which the standard puts at the top left. Which
/// of the other two is top right and which is bottom left is a question of
/// handedness, and the sign of the cross product answers it.
List<_Corner> _order(List<_Corner> raw) {
  final zeroOne = _distance(raw[0], raw[1]);
  final oneTwo = _distance(raw[1], raw[2]);
  final zeroTwo = _distance(raw[0], raw[2]);

  _Corner topLeft;
  _Corner a;
  _Corner c;
  if (oneTwo >= zeroOne && oneTwo >= zeroTwo) {
    topLeft = raw[0];
    a = raw[1];
    c = raw[2];
  } else if (zeroTwo >= oneTwo && zeroTwo >= zeroOne) {
    topLeft = raw[1];
    a = raw[0];
    c = raw[2];
  } else {
    topLeft = raw[2];
    a = raw[0];
    c = raw[1];
  }

  final cross = (c.x - topLeft.x) * (a.y - topLeft.y) -
      (c.y - topLeft.y) * (a.x - topLeft.x);
  if (cross < 0) {
    final swap = a;
    a = c;
    c = swap;
  }

  // bottom left, top left, top right
  return [a, topLeft, c];
}

/// Measure the module pitch along the line joining two corner squares.
///
/// The obvious shortcut is to take the module size each corner square reported
/// when it was found. That number comes from a horizontal scan line, and a
/// horizontal line across a square rotated by forty-five degrees is its
/// diagonal: forty-one percent too long. Using it would put the estimated size
/// of the whole symbol out by the same factor, and nothing downstream would
/// survive that.
///
/// So the measurement is taken in the direction that matters. Walking outward
/// from one centre toward the other crosses dark, light, dark: half the centre
/// square, the white ring, and the outer ring. Doing it in both directions
/// spans seven modules, which is the corner square's width by definition.
double _moduleSizeBetween(_Bin img, _Corner from, _Corner to) {
  final one = _runBothWays(img, from.x.round(), from.y.round(), to.x.round(),
      to.y.round());
  final other = _runBothWays(img, to.x.round(), to.y.round(), from.x.round(),
      from.y.round());

  if (one.isNaN && other.isNaN) return double.nan;
  if (one.isNaN) return other / 7.0;
  if (other.isNaN) return one / 7.0;
  return (one + other) / 14.0;
}

double _runBothWays(_Bin img, int fromX, int fromY, int toX, int toY) {
  var length = _run(img, fromX, fromY, toX, toY);

  // The same distance in the opposite direction, clipped to the frame so the
  // walk does not run off the edge and report a short run as a real one.
  var scale = 1.0;
  var backX = fromX - (toX - fromX);
  if (backX < 0) {
    scale = fromX / (fromX - backX);
    backX = 0;
  } else if (backX >= img.width) {
    scale = (img.width - 1 - fromX) / (backX - fromX);
    backX = img.width - 1;
  }
  var backY = (fromY - (toY - fromY) * scale).round();

  scale = 1.0;
  if (backY < 0) {
    scale = fromY / (fromY - backY);
    backY = 0;
  } else if (backY >= img.height) {
    scale = (img.height - 1 - fromY) / (backY - fromY);
    backY = img.height - 1;
  }
  backX = (fromX + (backX - fromX) * scale).round();

  length += _run(img, fromX, fromY, backX, backY);

  // The starting pixel belongs to both halves.
  return length - 1.0;
}

/// Walk a line and return the distance covered by dark, light, dark.
double _run(_Bin img, int fromX, int fromY, int toX, int toY) {
  final steep = (toY - fromY).abs() > (toX - fromX).abs();
  if (steep) {
    var t = fromX;
    fromX = fromY;
    fromY = t;
    t = toX;
    toX = toY;
    toY = t;
  }

  final dx = (toX - fromX).abs();
  final dy = (toY - fromY).abs();
  var error = -dx ~/ 2;
  final xStep = fromX < toX ? 1 : -1;
  final yStep = fromY < toY ? 1 : -1;

  var state = 0;
  final limit = toX + xStep;
  var y = fromY;

  for (var x = fromX; x != limit; x += xStep) {
    final atX = steep ? y : x;
    final atY = steep ? x : y;

    // Dark is expected in states 0 and 2, light in state 1. Seeing the other
    // one means a boundary was crossed.
    if ((state == 1) == img.get(atX, atY)) {
      if (state == 2) {
        final ddx = (x - fromX).toDouble();
        final ddy = (y - fromY).toDouble();
        return sqrt(ddx * ddx + ddy * ddy);
      }
      state++;
    }

    error += dy;
    if (error > 0) {
      if (y == toY) break;
      y += yStep;
      error -= dx;
    }
  }

  if (state == 2) {
    final ddx = (toX + xStep - fromX).toDouble();
    final ddy = (toY - fromY).toDouble();
    return sqrt(ddx * ddx + ddy * ddy);
  }
  return double.nan;
}

/// A projective map from module coordinates to pixel coordinates.
///
/// An affine map would be enough for a code lying flat under the camera. It is
/// not enough for one held at an angle, where the far edge is genuinely
/// shorter than the near one, and that is the common case when someone points
/// a phone at another phone's screen.
class _Projection {
  const _Projection(this.a11, this.a21, this.a31, this.a12, this.a22, this.a32,
      this.a13, this.a23, this.a33);

  final double a11, a21, a31, a12, a22, a32, a13, a23, a33;

  /// Map the unit square's corners to an arbitrary quadrilateral.
  factory _Projection.fromUnitSquare(double x0, double y0, double x1, double y1,
      double x2, double y2, double x3, double y3) {
    final dx3 = x0 - x1 + x2 - x3;
    final dy3 = y0 - y1 + y2 - y3;

    if (dx3 == 0.0 && dy3 == 0.0) {
      return _Projection(
          x1 - x0, x2 - x1, x0, y1 - y0, y2 - y1, y0, 0.0, 0.0, 1.0);
    }

    final dx1 = x1 - x2;
    final dx2 = x3 - x2;
    final dy1 = y1 - y2;
    final dy2 = y3 - y2;
    final denominator = dx1 * dy2 - dx2 * dy1;
    final a13 = (dx3 * dy2 - dx2 * dy3) / denominator;
    final a23 = (dx1 * dy3 - dx3 * dy1) / denominator;

    return _Projection(x1 - x0 + a13 * x1, x3 - x0 + a23 * x3, x0,
        y1 - y0 + a13 * y1, y3 - y0 + a23 * y3, y0, a13, a23, 1.0);
  }

  _Projection get inverse => _Projection(
      a22 * a33 - a23 * a32,
      a23 * a31 - a21 * a33,
      a21 * a32 - a22 * a31,
      a13 * a32 - a12 * a33,
      a11 * a33 - a13 * a31,
      a12 * a31 - a11 * a32,
      a12 * a23 - a13 * a22,
      a13 * a21 - a11 * a23,
      a11 * a22 - a12 * a21);

  _Projection then(_Projection o) => _Projection(
      a11 * o.a11 + a21 * o.a12 + a31 * o.a13,
      a11 * o.a21 + a21 * o.a22 + a31 * o.a23,
      a11 * o.a31 + a21 * o.a32 + a31 * o.a33,
      a12 * o.a11 + a22 * o.a12 + a32 * o.a13,
      a12 * o.a21 + a22 * o.a22 + a32 * o.a23,
      a12 * o.a31 + a22 * o.a32 + a32 * o.a33,
      a13 * o.a11 + a23 * o.a12 + a33 * o.a13,
      a13 * o.a21 + a23 * o.a22 + a33 * o.a23,
      a13 * o.a31 + a23 * o.a32 + a33 * o.a33);

  /// Map one point. Returns null when it falls behind the projection plane.
  Point<double>? apply(double x, double y) {
    final w = a13 * x + a23 * y + a33;
    if (w == 0.0 || !w.isFinite) return null;
    return Point((a11 * x + a21 * y + a31) / w, (a12 * x + a22 * y + a32) / w);
  }

  /// Map a quadrilateral in one space onto a quadrilateral in another.
  static _Projection between(List<double> from, List<double> to) =>
      _Projection.fromUnitSquare(to[0], to[1], to[2], to[3], to[4], to[5], to[6],
              to[7])
          .then(_Projection.fromUnitSquare(from[0], from[1], from[2], from[3],
                  from[4], from[5], from[6], from[7])
              .inverse);
}

/// Find alignment squares near where the fourth corner should be.
///
/// Returns candidates nearest the estimate first, and more than one on purpose.
///
/// The estimate this searches around comes from assuming the code is a
/// parallelogram, which is exactly the assumption the alignment square exists
/// to correct. On a code held at a steep angle that estimate can be tens of
/// pixels out, so the search has to widen, and a wide search over dense data
/// modules will sooner or later find a light-dark-light run that is not an
/// alignment square at all.
///
/// Returning one candidate means committing to that mistake. Returning several
/// lets the caller decode with each and let Reed-Solomon settle it, which is
/// the only judge that cannot be fooled.
List<_Corner> _findAlignment(_Bin img, double moduleSize, int estX, int estY) {
  // The three runs are light, dark, light: the ring around the centre module,
  // the centre module itself, and the ring on the other side. Centring on the
  // dark run in the middle is the whole point, and centring on either light
  // ring instead puts the fourth corner a full module out.
  bool ratioHolds(List<int> runs) {
    final slack = moduleSize / 2.0;
    for (final run in runs) {
      if ((moduleSize - run).abs() >= slack) return false;
    }
    return true;
  }

  for (final reach in const [4, 8, 16]) {
    final span = (moduleSize * reach).round();
    final left = max(0, estX - span);
    final right = min(img.width - 1, estX + span);
    final top = max(0, estY - span);
    final bottom = min(img.height - 1, estY + span);
    if (right - left < moduleSize * 3 || bottom - top < moduleSize * 3) continue;

    final seen = <_Corner>[];
    final confirmed = <_Corner>[];

    _Corner? consider(List<int> runs, int y, int endX) {
      final centreX = (endX - runs[2]) - runs[1] / 2.0;
      final centreY = _alignmentVertical(
          img, centreX.round(), y, 2 * runs[1], runs[0] + runs[1] + runs[2]);
      if (centreY.isNaN) return null;

      final size = (runs[0] + runs[1] + runs[2]) / 3.0;
      for (final c in seen) {
        if (c.sameAs(centreX, centreY, size)) {
          // A second sighting on a different row. One row can be a fluke; two
          // rows agreeing on the same centre is a pattern.
          c.absorb(centreX, centreY, size);
          if (!confirmed.contains(c)) confirmed.add(c);
          return c;
        }
      }
      seen.add(_Corner(centreX, centreY, size));
      return null;
    }

    for (var offset = 0; offset <= bottom - top; offset++) {
      // Rows in outward order from the estimate, nearest first.
      final y = estY +
          (offset.isEven ? (offset + 1) ~/ 2 : -((offset + 1) ~/ 2));
      if (y < top || y > bottom) continue;

      final runs = [0, 0, 0];
      var state = 0;
      var x = left;

      // A light run that starts at the edge of the region has no measurable
      // length, so it is stepped over rather than counted short.
      while (x < right && !img.get(x, y)) {
        x++;
      }

      while (x < right) {
        if (img.get(x, y)) {
          if (state == 1) {
            runs[1]++;
          } else if (state == 2) {
            if (ratioHolds(runs)) consider(runs, y, x);
            runs[0] = runs[2];
            runs[1] = 1;
            runs[2] = 0;
            state = 1;
          } else {
            runs[++state]++;
          }
        } else {
          if (state == 1) state++;
          runs[state]++;
        }
        x++;
      }

      if (state == 2 && ratioHolds(runs)) consider(runs, y, right);
    }

    if (confirmed.isNotEmpty) {
      // Nearest the estimate first: the correct square usually is, and the
      // caller stops at the first candidate that decodes.
      double away(_Corner c) {
        final dx = c.x - estX;
        final dy = c.y - estY;
        return dx * dx + dy * dy;
      }

      confirmed.sort((a, b) => away(a).compareTo(away(b)));
      return confirmed.take(4).toList();
    }
  }
  return const [];
}

/// Confirm the centre module vertically and return its row.
double _alignmentVertical(_Bin img, int atX, int fromY, int maxRun, int wanted) {
  final runs = [0, 0, 0];

  var y = fromY;
  while (y >= 0 && img.get(atX, y) && runs[1] <= maxRun) {
    runs[1]++;
    y--;
  }
  if (y < 0 || runs[1] > maxRun) return double.nan;
  while (y >= 0 && !img.get(atX, y) && runs[0] <= maxRun) {
    runs[0]++;
    y--;
  }
  if (runs[0] > maxRun) return double.nan;

  y = fromY + 1;
  while (y < img.height && img.get(atX, y) && runs[1] <= maxRun) {
    runs[1]++;
    y++;
  }
  if (y == img.height || runs[1] > maxRun) return double.nan;
  while (y < img.height && !img.get(atX, y) && runs[2] <= maxRun) {
    runs[2]++;
    y++;
  }
  if (runs[2] > maxRun) return double.nan;

  final total = runs[0] + runs[1] + runs[2];
  if (5 * (total - wanted).abs() >= 2 * wanted) return double.nan;

  return (y - runs[2]) - runs[1] / 2.0;
}

// -----------------------------------------------------------------------------
// Putting it together
// -----------------------------------------------------------------------------

/// Read the first QR code in this frame, or return null.
///
/// Null is the ordinary outcome. This runs on every frame the camera produces,
/// and most of them contain nothing.
QrResult? scan(Luma image) {
  final img = _binarise(image);
  final corners = _findCorners(img);
  if (corners.length < 3) return null;

  // Sightings confirmed more than once are more likely to be real, and a frame
  // with clutter can turn up more than three candidates.
  corners.sort((a, b) => b.seen.compareTo(a.seen));
  final pool = corners.take(6).toList();

  for (var i = 0; i < pool.length - 2; i++) {
    for (var j = i + 1; j < pool.length - 1; j++) {
      for (var k = j + 1; k < pool.length; k++) {
        final result = _attempt(img, [pool[i], pool[j], pool[k]]);
        if (result != null) return result;
      }
    }
  }

  return null;
}

QrResult? _attempt(_Bin img, List<_Corner> three) {
  final ordered = _order(three);
  final bottomLeft = ordered[0];
  final topLeft = ordered[1];
  final topRight = ordered[2];

  final across_ = _moduleSizeBetween(img, topLeft, topRight);
  final down_ = _moduleSizeBetween(img, topLeft, bottomLeft);
  var moduleSize = (across_ + down_) / 2.0;
  if (moduleSize.isNaN) {
    // Both walks ran off the frame. The sizes reported when the squares were
    // found are worse, but they are better than giving up.
    moduleSize = (topLeft.size + topRight.size + bottomLeft.size) / 3.0;
  }
  if (!(moduleSize >= 1.0)) return null;

  // Distance between two finder centres, in modules, plus the seven modules of
  // the two half-squares that sit outside them.
  final across = (_distance(topLeft, topRight) / moduleSize).round();
  final down = (_distance(topLeft, bottomLeft) / moduleSize).round();
  var dimension = (across + down) ~/ 2 + 7;

  // Every legal size is one more than a multiple of four, so the nearest legal
  // size is a correction rather than a guess. A remainder of three means the
  // estimate is too far out to correct honestly.
  switch (dimension & 0x03) {
    case 0:
      dimension++;
    case 2:
      dimension--;
    case 3:
      return null;
  }
  if (dimension < 21 || dimension > 177) return null;

  final version = (dimension - 17) ~/ 4;
  final edge = dimension - 3.5;

  // Where the fourth corner would be if the code were perfectly flat.
  final flatX = topRight.x - topLeft.x + bottomLeft.x;
  final flatY = topRight.y - topLeft.y + bottomLeft.y;

  var alignments = const <_Corner>[];

  if (version > 1) {
    // The last alignment square sits three modules in from the corner. Pull the
    // estimate back by that much before looking for it.
    final between = dimension - 7;
    final pull = 1.0 - 3.0 / between;
    final guessX = topLeft.x + pull * (flatX - topLeft.x);
    final guessY = topLeft.y + pull * (flatY - topLeft.y);

    alignments =
        _findAlignment(img, moduleSize, guessX.round(), guessY.round());
  }

  // Two hypotheses about where the fourth corner is, tried in order of
  // trustworthiness. The alignment square is a measurement and the extrapolated
  // corner is a guess, but a guess that happens to be right beats a measurement
  // taken on the wrong square, and only decoding can tell them apart.
  final corners = <List<double>>[
    for (final a in alignments) [edge - 3.0, edge - 3.0, a.x, a.y],
    [edge, edge, flatX, flatY],
  ];

  for (final corner in corners) {
    final projection = _Projection.between(
      [3.5, 3.5, edge, 3.5, corner[0], corner[1], 3.5, edge],
      [
        topLeft.x,
        topLeft.y,
        topRight.x,
        topRight.y,
        corner[2],
        corner[3],
        bottomLeft.x,
        bottomLeft.y,
      ],
    );

    final matrix = _sample(img, projection, dimension);
    if (matrix == null) continue;

    final result = decodeMatrix(matrix);
    if (result != null) return result;
  }

  return null;
}

/// Read the module grid through [projection].
///
/// Each module is decided by five samples, not one: its centre and four points
/// a quarter of a module out. Where the symbol is large in frame this changes
/// nothing, since all five land well inside the same module.
///
/// Where it matters is the case this app actually meets, a code on somebody
/// else's screen filling part of the frame, six or seven pixels to a module.
/// There a transform that is fractionally off puts the centre sample on the
/// wrong side of a boundary, and a single wrong sample is a wrong bit. Five
/// samples voting means the transform has to be off by a good deal more than
/// half a module before the answer changes.
QrMatrix? _sample(_Bin img, _Projection projection, int dimension) {
  final matrix = QrMatrix(dimension);

  // A quarter of a module, in module coordinates. The projection turns that
  // into whatever it is in pixels, which is the point: the offset has to scale
  // with the symbol, and near the far edge of a code held at an angle a module
  // is physically smaller than near the close edge.
  const reach = 0.25;

  for (var row = 0; row < dimension; row++) {
    for (var col = 0; col < dimension; col++) {
      var dark = 0;
      var read = 0;

      for (final offset in const [
        [0.0, 0.0],
        [-1.0, 0.0],
        [1.0, 0.0],
        [0.0, -1.0],
        [0.0, 1.0],
      ]) {
        final at = projection.apply(
            col + 0.5 + offset[0] * reach, row + 0.5 + offset[1] * reach);
        if (at == null) continue;
        final x = at.x.round();
        final y = at.y.round();
        if (x < 0 || y < 0 || x >= img.width || y >= img.height) continue;
        read++;
        if (img.get(x, y)) dark++;
      }

      // Not one usable sample means the grid has left the frame, and a matrix
      // with holes in it decodes to confident nonsense.
      if (read == 0) return null;
      matrix.set(row, col, dark * 2 > read);
    }
  }

  return matrix;
}
