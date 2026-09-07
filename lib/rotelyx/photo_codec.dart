/// A picture codec of this application's own, for envelopes that are small.
///
/// # Why there is one at all
///
/// The mailbox takes 64 KiB in one envelope on the free tier. A photograph off
/// a phone is three to eight megabytes, and the shrinking this application did
/// before re-encoded as PNG, because the Flutter engine offers PNG and raw
/// pixels and nothing else. PNG of a photograph is several times the size of a
/// lossy encoding of the same picture, so hitting 64 KiB that way meant drawing
/// the photograph at about 300 pixels on its long edge. That is a stamp, not a
/// picture, and it is why sending one was refused.
///
/// Both ends of a conversation are this application, so the format between them
/// does not have to be one anybody else can read. This is that format.
///
/// # What it is, honestly
///
/// It is DCT shaped: colour separated from brightness, chroma at half
/// resolution, eight by eight blocks, a frequency transform, quantisation, and
/// an entropy coder. That is the shape of JPEG and of everything that has
/// beaten JPEG, because at these sizes it is the shape that works. A format
/// that departed from it to be different would look worse, and looking better
/// is the entire point.
///
/// Where it differs is worth stating plainly, because it is the difference that
/// pays for the file existing:
///
///   * **An adaptive binary arithmetic coder** rather than JPEG's Huffman
///     tables. Probabilities are learned from the picture as it is written
///     instead of being fixed in advance, which is worth roughly a tenth of the
///     file at no cost in quality. JPEG has an arithmetic mode that says the
///     same thing; almost nothing implements it, for patent reasons that
///     expired long ago and habits that did not.
///   * **Quantisation tuned for small files.** JPEG's tables were fitted for
///     photographs at a few hundred kilobytes. These are steeper in the high
///     frequencies, which is where a picture at 64 KiB has nothing to spend.
///   * **No headers to speak of.** Ten bytes, because there is no need to
///     describe tables both sides already have, or a colour space that is
///     always the same one.
///
/// # What it does not do
///
/// It does not beat AVIF, and nothing written in an afternoon does. If the
/// engine ever exposes a modern encoder to Dart, this should be measured
/// against it and dropped without ceremony if it loses.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// What every picture from this codec begins with.
///
/// Four bytes, so a decoder can refuse something that is not one of ours before
/// it starts reading numbers out of it.
const List<int> photoMagic = [0x52, 0x58, 0x50, 0x31]; // "RXP1"

/// The MIME type an encoded picture travels under.
///
/// Deliberately not `image/jpeg` or anything else a platform might try to
/// decode itself and fail at. Anything that does not know this type shows the
/// attachment as a file, which is wrong but not broken.
const String photoMime = 'image/x-rotelyx';

/// Zigzag order, which is the order the eight by eight block is read in.
///
/// Low frequencies first, so the coefficients that carry the picture come
/// before the ones that carry the grain, and the run of zeroes at the end is
/// one run rather than sixty scattered gaps.
const List<int> _zigzag = [
  0, 1, 8, 16, 9, 2, 3, 10, //
  17, 24, 32, 25, 18, 11, 4, 5,
  12, 19, 26, 33, 40, 48, 41, 34,
  27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36,
  29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46,
  53, 60, 61, 54, 47, 55, 62, 63,
];

/// How much of each frequency is thrown away, for brightness.
///
/// Steeper than JPEG's table in the bottom right corner. A picture allowed 64
/// KiB cannot afford fine detail, and spending bits on it takes them from the
/// shapes and edges that are what somebody actually looks at.
const List<int> _quantLuma = [
  16, 12, 14, 18, 24, 40, 62, 78, //
  12, 13, 16, 21, 30, 56, 72, 84,
  14, 16, 19, 26, 44, 68, 86, 92,
  18, 21, 26, 34, 62, 92, 108, 100,
  24, 30, 44, 62, 82, 118, 140, 116,
  40, 56, 68, 92, 118, 148, 172, 136,
  62, 72, 86, 108, 140, 172, 192, 154,
  78, 84, 92, 100, 116, 136, 154, 164,
];

/// And for colour, which the eye reads far less sharply.
const List<int> _quantChroma = [
  18, 20, 26, 50, 92, 92, 92, 92, //
  20, 23, 28, 62, 92, 92, 92, 92,
  26, 28, 54, 92, 92, 92, 92, 92,
  50, 62, 92, 92, 92, 92, 92, 92,
  92, 92, 92, 92, 92, 92, 92, 92,
  92, 92, 92, 92, 92, 92, 92, 92,
  92, 92, 92, 92, 92, 92, 92, 92,
  92, 92, 92, 92, 92, 92, 92, 92,
];

/// The tables above, scaled to a quality between 1 and 100.
///
/// The same curve JPEG uses, because it is a sensible one: below fifty the
/// divisor grows quickly and above it shrinks slowly, which matches how quickly
/// a picture stops looking like itself.
Uint8List _scale(List<int> base, int quality) {
  final q = quality.clamp(1, 100);
  final factor = q < 50 ? 5000 ~/ q : 200 - q * 2;
  final out = Uint8List(64);
  for (var i = 0; i < 64; i++) {
    out[i] = ((base[i] * factor + 50) ~/ 100).clamp(1, 255);
  }
  return out;
}

// ---------------------------------------------------------------------------
// The arithmetic coder.
//
// A binary range coder with adaptive contexts: every bit is written against a
// probability that is updated from the bits already written, so a picture whose
// coefficients are mostly zero pays almost nothing for the zeroes rather than
// paying a fixed code length for each.
//
// The shape is the one used in most modern codecs. Twelve bit probabilities,
// carry handled by counting pending 0xFF bytes on the way out.
// ---------------------------------------------------------------------------

/// One adaptive probability, twelve bits, halfway to begin with.
class _Bit {
  int p = 2048;

  /// Moved a thirty-second of the way towards the bit that just happened.
  ///
  /// Fast enough to follow a picture that changes and slow enough not to be
  /// thrown by one unusual block.
  void update(int bit) {
    if (bit == 0) {
      p += (4096 - p) >> 5;
    } else {
      p -= p >> 5;
    }
  }
}

class _Writer {
  final BytesBuilder _out = BytesBuilder(copy: false);
  int _low = 0;
  int _range = 0xFFFFFFFF;
  int _cache = 0xFF;
  int _pending = 0;
  bool _started = false;

  void bit(_Bit ctx, int value) {
    final bound = (_range >> 12) * ctx.p;
    if (value == 0) {
      _range = bound;
    } else {
      _low += bound;
      _range -= bound;
    }
    ctx.update(value);

    while (_range < 0x1000000) {
      _shift();
      _range = (_range << 8) & 0xFFFFFFFF;
    }
  }

  /// A bit with no context, for values that are as likely either way.
  void raw(int value) {
    _range = _range >> 1;
    if (value != 0) _low += _range;
    while (_range < 0x1000000) {
      _shift();
      _range = (_range << 8) & 0xFFFFFFFF;
    }
  }

  void _shift() {
    final carry = _low >> 32;
    if (_low < 0xFF000000 || carry == 1) {
      if (_started) _out.addByte((_cache + carry) & 0xFF);
      _started = true;
      while (_pending > 0) {
        _out.addByte((0xFF + carry) & 0xFF);
        _pending--;
      }
      _cache = (_low >> 24) & 0xFF;
    } else {
      _pending++;
    }
    _low = (_low << 8) & 0xFFFFFFFF;
  }

  Uint8List finish() {
    for (var i = 0; i < 5; i++) {
      _shift();
    }
    return _out.takeBytes();
  }
}

class _Reader {
  _Reader(this._in, this._at) {
    for (var i = 0; i < 4; i++) {
      _code = ((_code << 8) | _next()) & 0xFFFFFFFF;
    }
  }

  final Uint8List _in;
  int _at;
  int _range = 0xFFFFFFFF;
  int _code = 0;

  int _next() => _at < _in.length ? _in[_at++] : 0;

  int bit(_Bit ctx) {
    final bound = (_range >> 12) * ctx.p;
    final int value;
    if (_code < bound) {
      _range = bound;
      value = 0;
    } else {
      _code -= bound;
      _range -= bound;
      value = 1;
    }
    ctx.update(value);

    while (_range < 0x1000000) {
      _code = ((_code << 8) | _next()) & 0xFFFFFFFF;
      _range = (_range << 8) & 0xFFFFFFFF;
    }
    return value;
  }

  int raw() {
    _range = _range >> 1;
    final int value;
    if (_code >= _range) {
      _code -= _range;
      value = 1;
    } else {
      value = 0;
    }
    while (_range < 0x1000000) {
      _code = ((_code << 8) | _next()) & 0xFFFFFFFF;
      _range = (_range << 8) & 0xFFFFFFFF;
    }
    return value;
  }
}

/// The probabilities one picture is written against.
///
/// Separate sets for brightness and colour, because their coefficients look
/// nothing alike, and separate contexts by position within the block, because
/// the chance of a coefficient being zero rises steeply with frequency.
class _Model {
  _Model()
      : significant = List.generate(2, (_) => List.generate(64, (_) => _Bit())),
        more = List.generate(2, (_) => List.generate(16, (_) => _Bit())),
        dcSign = List.generate(2, (_) => _Bit()),
        dcMore = List.generate(2, (_) => List.generate(16, (_) => _Bit()));

  /// Whether the coefficient at this position is anything but zero.
  final List<List<_Bit>> significant;

  /// The unary tail that says how big it is.
  final List<List<_Bit>> more;

  final List<_Bit> dcSign;
  final List<List<_Bit>> dcMore;
}

/// Write a value as a run of "there is more" bits and then its remainder.
///
/// Exp-Golomb shaped: small numbers, which is nearly all of them, cost a few
/// bits, and the length of a large one grows with its logarithm rather than
/// with the number itself.
void _putValue(_Writer w, List<_Bit> ctx, int magnitude) {
  var k = 0;
  while (k < 15 && magnitude >= (1 << (k + 1))) {
    w.bit(ctx[k], 1);
    k++;
  }
  if (k < 15) w.bit(ctx[k], 0);

  for (var i = k - 1; i >= 0; i--) {
    w.raw((magnitude >> i) & 1);
  }
}

int _getValue(_Reader r, List<_Bit> ctx) {
  var k = 0;
  while (k < 15 && r.bit(ctx[k]) == 1) {
    k++;
  }
  var magnitude = 1 << k;
  for (var i = k - 1; i >= 0; i--) {
    magnitude |= r.raw() << i;
  }
  return magnitude;
}

// ---------------------------------------------------------------------------
// The transform.
// ---------------------------------------------------------------------------

/// Cosines, worked out once.
final Float32List _cos = () {
  final table = Float32List(64);
  for (var u = 0; u < 8; u++) {
    for (var x = 0; x < 8; x++) {
      table[u * 8 + x] = math.cos((2 * x + 1) * u * math.pi / 16);
    }
  }
  return table;
}();

final Float32List _alpha = () {
  final a = Float32List(8);
  a[0] = 1 / math.sqrt(2);
  for (var i = 1; i < 8; i++) {
    a[i] = 1;
  }
  return a;
}();

/// Separable, so sixty-four multiplies a row rather than four thousand a block.
void _forward(Float32List block, Float32List out) {
  final rows = Float32List(64);
  for (var y = 0; y < 8; y++) {
    for (var u = 0; u < 8; u++) {
      var sum = 0.0;
      for (var x = 0; x < 8; x++) {
        sum += block[y * 8 + x] * _cos[u * 8 + x];
      }
      rows[y * 8 + u] = sum * _alpha[u] * 0.5;
    }
  }
  for (var u = 0; u < 8; u++) {
    for (var v = 0; v < 8; v++) {
      var sum = 0.0;
      for (var y = 0; y < 8; y++) {
        sum += rows[y * 8 + u] * _cos[v * 8 + y];
      }
      out[v * 8 + u] = sum * _alpha[v] * 0.5;
    }
  }
}

void _inverse(Float32List block, Float32List out) {
  final rows = Float32List(64);
  for (var v = 0; v < 8; v++) {
    for (var x = 0; x < 8; x++) {
      var sum = 0.0;
      for (var u = 0; u < 8; u++) {
        sum += _alpha[u] * block[v * 8 + u] * _cos[u * 8 + x];
      }
      rows[v * 8 + x] = sum * 0.5;
    }
  }
  for (var x = 0; x < 8; x++) {
    for (var y = 0; y < 8; y++) {
      var sum = 0.0;
      for (var v = 0; v < 8; v++) {
        sum += _alpha[v] * rows[v * 8 + x] * _cos[v * 8 + y];
      }
      out[y * 8 + x] = sum * 0.5;
    }
  }
}

// ---------------------------------------------------------------------------
// Colour.
// ---------------------------------------------------------------------------

/// One picture's worth of planes, brightness at full size and colour at half.
class _Planes {
  _Planes(this.w, this.h)
      : cw = (w + 1) >> 1,
        ch = (h + 1) >> 1,
        y = Float32List(w * h) {
    cb = Float32List(cw * ch);
    cr = Float32List(cw * ch);
  }

  final int w;
  final int h;
  final int cw;
  final int ch;
  final Float32List y;
  late final Float32List cb;
  late final Float32List cr;
}

/// BT.601, which is what everything that shows a photograph on a phone assumes.
_Planes _split(Uint8List rgba, int w, int h) {
  final planes = _Planes(w, h);
  final cbSum = Float32List(planes.cw * planes.ch);
  final crSum = Float32List(planes.cw * planes.ch);
  final counts = Int32List(planes.cw * planes.ch);

  for (var yy = 0; yy < h; yy++) {
    for (var xx = 0; xx < w; xx++) {
      final i = (yy * w + xx) * 4;
      final r = rgba[i].toDouble();
      final g = rgba[i + 1].toDouble();
      final b = rgba[i + 2].toDouble();

      planes.y[yy * w + xx] = 0.299 * r + 0.587 * g + 0.114 * b - 128;

      final c = (yy >> 1) * planes.cw + (xx >> 1);
      cbSum[c] += -0.168736 * r - 0.331264 * g + 0.5 * b;
      crSum[c] += 0.5 * r - 0.418688 * g - 0.081312 * b;
      counts[c]++;
    }
  }

  for (var i = 0; i < counts.length; i++) {
    final n = counts[i] == 0 ? 1 : counts[i];
    planes.cb[i] = cbSum[i] / n;
    planes.cr[i] = crSum[i] / n;
  }
  return planes;
}

Uint8List _join(_Planes planes) {
  final w = planes.w;
  final h = planes.h;
  final rgba = Uint8List(w * h * 4);

  for (var yy = 0; yy < h; yy++) {
    for (var xx = 0; xx < w; xx++) {
      final c = (yy >> 1) * planes.cw + (xx >> 1);
      final luma = planes.y[yy * w + xx] + 128;
      final cb = planes.cb[c];
      final cr = planes.cr[c];

      final i = (yy * w + xx) * 4;
      rgba[i] = (luma + 1.402 * cr).round().clamp(0, 255);
      rgba[i + 1] =
          (luma - 0.344136 * cb - 0.714136 * cr).round().clamp(0, 255);
      rgba[i + 2] = (luma + 1.772 * cb).round().clamp(0, 255);
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

// ---------------------------------------------------------------------------
// The plane loop.
// ---------------------------------------------------------------------------

void _writePlane(
  _Writer w,
  _Model model,
  Float32List plane,
  int width,
  int height,
  Uint8List quant,
  int kind,
) {
  final block = Float32List(64);
  final coeffs = Float32List(64);
  var previousDc = 0;

  for (var by = 0; by < height; by += 8) {
    for (var bx = 0; bx < width; bx += 8) {
      // Edges are filled by repeating the last real pixel rather than by
      // padding with grey, which would put an edge into the picture at the
      // border and cost bits to describe.
      for (var y = 0; y < 8; y++) {
        final sy = math.min(by + y, height - 1);
        for (var x = 0; x < 8; x++) {
          final sx = math.min(bx + x, width - 1);
          block[y * 8 + x] = plane[sy * width + sx];
        }
      }

      _forward(block, coeffs);

      // DC first, as a difference from the block before it. Neighbouring
      // blocks of a photograph are close in average brightness, so the
      // difference is small where the value is not.
      final dc = (coeffs[0] / quant[0]).round();
      final diff = dc - previousDc;
      previousDc = dc;

      if (diff == 0) {
        w.bit(model.significant[kind][0], 0);
      } else {
        w.bit(model.significant[kind][0], 1);
        w.bit(model.dcSign[kind], diff < 0 ? 1 : 0);
        _putValue(w, model.dcMore[kind], diff.abs());
      }

      for (var i = 1; i < 64; i++) {
        final z = _zigzag[i];
        final value = (coeffs[z] / quant[i]).round();
        if (value == 0) {
          w.bit(model.significant[kind][i], 0);
        } else {
          w.bit(model.significant[kind][i], 1);
          w.raw(value < 0 ? 1 : 0);
          _putValue(w, model.more[kind], value.abs());
        }
      }
    }
  }
}

void _readPlane(
  _Reader r,
  _Model model,
  Float32List plane,
  int width,
  int height,
  Uint8List quant,
  int kind,
) {
  final coeffs = Float32List(64);
  final block = Float32List(64);
  var previousDc = 0;

  for (var by = 0; by < height; by += 8) {
    for (var bx = 0; bx < width; bx += 8) {
      for (var i = 0; i < 64; i++) {
        coeffs[i] = 0;
      }

      var dc = previousDc;
      if (r.bit(model.significant[kind][0]) == 1) {
        final negative = r.bit(model.dcSign[kind]) == 1;
        final magnitude = _getValue(r, model.dcMore[kind]);
        dc = previousDc + (negative ? -magnitude : magnitude);
      }
      previousDc = dc;
      coeffs[0] = (dc * quant[0]).toDouble();

      for (var i = 1; i < 64; i++) {
        if (r.bit(model.significant[kind][i]) == 0) continue;
        final negative = r.raw() == 1;
        final magnitude = _getValue(r, model.more[kind]);
        final value = negative ? -magnitude : magnitude;
        coeffs[_zigzag[i]] = (value * quant[i]).toDouble();
      }

      _inverse(coeffs, block);

      for (var y = 0; y < 8; y++) {
        final dy = by + y;
        if (dy >= height) break;
        for (var x = 0; x < 8; x++) {
          final dx = bx + x;
          if (dx >= width) break;
          plane[dy * width + dx] = block[y * 8 + x];
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// What the rest of the application calls.
// ---------------------------------------------------------------------------

/// Encode one picture at one quality.
///
/// [rgba] is four bytes a pixel, which is what the engine hands back.
Uint8List encodePhoto(Uint8List rgba, int width, int height,
    {int quality = 70}) {
  final planes = _split(rgba, width, height);
  final luma = _scale(_quantLuma, quality);
  final chroma = _scale(_quantChroma, quality);

  final w = _Writer();
  final model = _Model();
  _writePlane(w, model, planes.y, width, height, luma, 0);
  _writePlane(w, model, planes.cb, planes.cw, planes.ch, chroma, 1);
  _writePlane(w, model, planes.cr, planes.cw, planes.ch, chroma, 1);
  final body = w.finish();

  final out = Uint8List(10 + body.length);
  out.setRange(0, 4, photoMagic);
  out[4] = width & 0xFF;
  out[5] = (width >> 8) & 0xFF;
  out[6] = height & 0xFF;
  out[7] = (height >> 8) & 0xFF;
  out[8] = quality.clamp(1, 100);
  out[9] = 0;
  out.setRange(10, out.length, body);
  return out;
}

/// What a decoded picture is: its size and its pixels.
class DecodedPhoto {
  const DecodedPhoto(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;
}

/// Whether these bytes are one of ours.
bool isRotelyxPhoto(Uint8List bytes) {
  if (bytes.length < 10) return false;
  for (var i = 0; i < 4; i++) {
    if (bytes[i] != photoMagic[i]) return false;
  }
  return true;
}

/// Decode one, or null when the bytes are not a picture of ours.
DecodedPhoto? decodePhoto(Uint8List bytes) {
  if (!isRotelyxPhoto(bytes)) return null;

  final width = bytes[4] | (bytes[5] << 8);
  final height = bytes[6] | (bytes[7] << 8);
  if (width <= 0 || height <= 0) return null;

  final quality = bytes[8];
  final luma = _scale(_quantLuma, quality);
  final chroma = _scale(_quantChroma, quality);

  final planes = _Planes(width, height);
  final r = _Reader(bytes, 10);
  final model = _Model();
  _readPlane(r, model, planes.y, width, height, luma, 0);
  _readPlane(r, model, planes.cb, planes.cw, planes.ch, chroma, 1);
  _readPlane(r, model, planes.cr, planes.cw, planes.ch, chroma, 1);

  return DecodedPhoto(width, height, _join(planes));
}
