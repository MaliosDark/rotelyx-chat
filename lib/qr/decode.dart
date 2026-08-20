/// Turning a grid of black and white squares back into the text it encodes.
///
/// # Why this is written out rather than imported
///
/// Every QR scanner package for Flutter web loads a JavaScript decoder from a
/// content delivery network at runtime. The Content-Security-Policy in
/// `web/index.html` refuses that, deliberately and correctly: the whole claim
/// this app makes is that it talks to nobody but its own mailbox, and a scanner
/// that fetches code from `cdn.jsdelivr.net` the first time a user opens the
/// camera would quietly end that claim.
///
/// The alternative would be to relax the policy for one feature. Reading a QR
/// code is arithmetic on a bitmap. It does not need a server, so it does not
/// get one.
///
/// # The stages, in order
///
/// A QR symbol is not a picture of its payload. Between the two sit five
/// reversible transformations, and this file undoes them in reverse:
///
///   1. **Format information.** Fifteen bits, stored twice, saying which of the
///      four correction levels was used and which of the eight masks was
///      applied. Read first, because nothing else can be read without them.
///   2. **The mask.** A checkerboard-like pattern XORed over the data so the
///      symbol has no large blank regions for the camera to lose track in.
///      Undoing it is XORing the same pattern back.
///   3. **The layout.** Data is written in a boustrophedon: two columns wide,
///      up the right edge, down the next pair, and so on, stepping over the
///      finder squares, the timing lines and the alignment squares.
///   4. **Interleaving.** The codewords are dealt out between blocks like
///      cards, so a scratch across the symbol damages a little of every block
///      instead of destroying one.
///   5. **Reed-Solomon.** Each block carries redundancy. This is the stage that
///      lets the logo sit in the middle of the code: those modules read as
///      noise, and the arithmetic reconstructs them.
///
/// Only then is there a bit stream, which segment decoding turns into text.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'tables.dart';

/// Callers need the correction level to talk about a result, so it comes along
/// with the decoder rather than making them reach into the table file.
export 'tables.dart' show QrLevel;

/// A square grid of modules. `true` is dark.
class QrMatrix {
  QrMatrix(this.dimension) : _bits = Uint8List(dimension * dimension);

  final int dimension;
  final Uint8List _bits;

  /// Version 1 is 21 modules across and every version adds four.
  int get version => (dimension - 17) ~/ 4;

  bool get(int row, int col) => _bits[row * dimension + col] != 0;
  void set(int row, int col, bool dark) =>
      _bits[row * dimension + col] = dark ? 1 : 0;
}

/// What a successful read produced.
class QrResult {
  const QrResult(this.text, {required this.version, required this.level});

  final String text;
  final int version;
  final QrLevel level;
}

/// Read a sampled matrix, or return null if it is not a coherent symbol.
///
/// Null rather than an exception because failure is the normal case: this runs
/// on every camera frame, and most frames contain no code at all.
QrResult? decodeMatrix(QrMatrix m) {
  final dim = m.dimension;
  if (dim < 21 || dim > 177 || (dim - 17) % 4 != 0) return null;

  final format = _readFormat(m);
  if (format == null) return null;

  final version = m.version;
  final raw = _readCodewords(m, format.mask);
  if (raw == null) return null;

  final blocks = _deinterleave(raw, version, format.level);
  if (blocks == null) return null;

  final data = BytesBuilder();
  for (final block in blocks) {
    if (!_correct(block.codewords, block.correctionCount)) return null;
    data.add(block.codewords.sublist(0, block.dataCount));
  }

  final text = _readSegments(data.toBytes(), version);
  if (text == null) return null;

  return QrResult(text, version: version, level: format.level);
}

// -----------------------------------------------------------------------------
// Stage 1: format information
// -----------------------------------------------------------------------------

class _Format {
  const _Format(this.level, this.mask);
  final QrLevel level;
  final int mask;
}

/// The mask the standard applies to the format bits before storing them.
///
/// Without it, a symbol at level M with mask 0 would store fifteen zeroes,
/// which is a large blank patch right where the scanner needs contrast.
const _formatMask = 0x5412;

/// Recover the correction level and mask pattern.
///
/// The fifteen bits are five of meaning and ten of BCH redundancy, and they are
/// stored in two places so a damaged corner is survivable. Both copies are
/// tried against all thirty-two legal values and the nearest is taken, so up to
/// three wrong bits still resolve.
_Format? _readFormat(QrMatrix m) {
  final dim = m.dimension;

  var a = 0;
  for (var col = 0; col < 6; col++) {
    a = (a << 1) | (m.get(8, col) ? 1 : 0);
  }
  a = (a << 1) | (m.get(8, 7) ? 1 : 0);
  a = (a << 1) | (m.get(8, 8) ? 1 : 0);
  a = (a << 1) | (m.get(7, 8) ? 1 : 0);
  for (var row = 5; row >= 0; row--) {
    a = (a << 1) | (m.get(row, 8) ? 1 : 0);
  }

  var b = 0;
  for (var row = dim - 1; row >= dim - 7; row--) {
    b = (b << 1) | (m.get(row, 8) ? 1 : 0);
  }
  for (var col = dim - 8; col < dim; col++) {
    b = (b << 1) | (m.get(8, col) ? 1 : 0);
  }

  return _bestFormat(a) ?? _bestFormat(b);
}

_Format? _bestFormat(int bits) {
  final unmasked = bits ^ _formatMask;

  var bestDistance = 32;
  var best = -1;

  for (var value = 0; value < 32; value++) {
    final encoded = _formatBch(value);
    if (encoded == unmasked) {
      best = value;
      bestDistance = 0;
      break;
    }
    final d = _popcount(encoded ^ unmasked);
    if (d < bestDistance) {
      bestDistance = d;
      best = value;
    }
  }

  // BCH(15,5) has minimum distance 7, so it corrects three errors. Accepting a
  // fourth would be guessing, and a guessed mask produces confident nonsense
  // rather than a clean failure.
  if (best < 0 || bestDistance > 3) return null;

  final levelIndex = levelBits.indexOf((best >> 3) & 0x03);
  if (levelIndex < 0) return null;

  return _Format(QrLevel.values[levelIndex], best & 0x07);
}

/// Append the ten BCH check bits to a five-bit format value.
int _formatBch(int value) {
  var d = value << 10;
  // Long division by the generator polynomial x^10 + x^8 + x^5 + x^4 + x^2 + x + 1.
  while (_bitLength(d) >= 11) {
    d ^= 0x537 << (_bitLength(d) - 11);
  }
  return (value << 10) | d;
}

int _bitLength(int v) {
  var n = 0;
  while (v != 0) {
    v >>= 1;
    n++;
  }
  return n;
}

int _popcount(int v) {
  var n = 0;
  while (v != 0) {
    n += v & 1;
    v >>= 1;
  }
  return n;
}

// -----------------------------------------------------------------------------
// Stage 2 and 3: the mask, and the layout
// -----------------------------------------------------------------------------

/// True where the module carries data rather than structure.
///
/// The finder squares, their white separators, the timing lines, the alignment
/// squares, the version blocks and the one permanently dark module are all
/// fixed by the standard. They are skipped when reading and they are never
/// masked.
Uint8List _functionPattern(int dimension, int version) {
  final f = Uint8List(dimension * dimension);
  void fill(int row, int col, int height, int width) {
    for (var r = row; r < row + height; r++) {
      if (r < 0 || r >= dimension) continue;
      for (var c = col; c < col + width; c++) {
        if (c < 0 || c >= dimension) continue;
        f[r * dimension + c] = 1;
      }
    }
  }

  // Finder squares with their separators, and the format strips beside them.
  fill(0, 0, 9, 9);
  fill(0, dimension - 8, 9, 8);
  fill(dimension - 8, 0, 8, 9);

  // Alignment squares, except the three that would sit on a finder.
  final centres = alignmentTable[version - 1];
  for (final r in centres) {
    for (final c in centres) {
      final onFinder = (r == 6 && c == 6) ||
          (r == 6 && c == dimension - 7) ||
          (r == dimension - 7 && c == 6);
      if (onFinder) continue;
      fill(r - 2, c - 2, 5, 5);
    }
  }

  // Timing lines, the alternating row and column that let a scanner count.
  for (var i = 0; i < dimension; i++) {
    f[6 * dimension + i] = 1;
    f[i * dimension + 6] = 1;
  }

  // Version information, present from version 7 where the symbol is large
  // enough that guessing the size from the geometry alone gets unreliable.
  if (version >= 7) {
    fill(dimension - 11, 0, 3, 6);
    fill(0, dimension - 11, 6, 3);
  }

  return f;
}

bool _masked(int mask, int row, int col) => switch (mask) {
      0 => (row + col) % 2 == 0,
      1 => row % 2 == 0,
      2 => col % 3 == 0,
      3 => (row + col) % 3 == 0,
      4 => (row ~/ 2 + col ~/ 3) % 2 == 0,
      5 => (row * col) % 2 + (row * col) % 3 == 0,
      6 => ((row * col) % 2 + (row * col) % 3) % 2 == 0,
      7 => ((row + col) % 2 + (row * col) % 3) % 2 == 0,
      _ => false,
    };

/// Walk the symbol in the order the standard writes it and unmask as we go.
///
/// The path is two modules wide, starting at the bottom right corner, running
/// up to the top, stepping two columns left, running back down, and repeating.
/// Column six is the vertical timing line and is stepped over entirely, which
/// is the one irregularity in an otherwise mechanical walk.
Uint8List? _readCodewords(QrMatrix m, int mask) {
  final dim = m.dimension;
  final function = _functionPattern(dim, m.version);

  final out = BytesBuilder();
  var current = 0;
  var bits = 0;
  var upward = true;

  for (var pair = dim - 1; pair > 0; pair -= 2) {
    if (pair == 6) pair--;
    for (var step = 0; step < dim; step++) {
      final row = upward ? dim - 1 - step : step;
      for (var offset = 0; offset < 2; offset++) {
        final col = pair - offset;
        if (function[row * dim + col] != 0) continue;

        var dark = m.get(row, col);
        if (_masked(mask, row, col)) dark = !dark;

        current = (current << 1) | (dark ? 1 : 0);
        bits++;
        if (bits == 8) {
          out.addByte(current);
          current = 0;
          bits = 0;
        }
      }
    }
    upward = !upward;
  }

  final result = out.toBytes();
  return result.isEmpty ? null : result;
}

// -----------------------------------------------------------------------------
// Stage 4: undoing the interleave
// -----------------------------------------------------------------------------

class _Block {
  _Block(this.codewords, this.dataCount, this.correctionCount);
  final Uint8List codewords;
  final int dataCount;
  final int correctionCount;
}

/// Deal the flat codeword stream back into the blocks it was dealt from.
///
/// A version can mix two block sizes, differing by exactly one data codeword.
/// The short ones come first, and the extra codeword of each long block is
/// written after every short block has had its turn. Getting this backwards
/// produces blocks that fail correction rather than blocks that decode wrongly,
/// which is at least a loud failure.
List<_Block>? _deinterleave(Uint8List raw, int version, QrLevel level) {
  final spec = rsBlockTable[version - 1][level.index];

  final blocks = <_Block>[];
  var correctionPerBlock = 0;
  var expected = 0;

  for (var i = 0; i < spec.length; i += 3) {
    final count = spec[i];
    final total = spec[i + 1];
    final dataCount = spec[i + 2];
    correctionPerBlock = total - dataCount;
    for (var j = 0; j < count; j++) {
      blocks.add(_Block(Uint8List(total), dataCount, correctionPerBlock));
      expected += total;
    }
  }

  if (raw.length < expected) return null;

  final shortest = blocks.first.dataCount;
  var at = 0;

  for (var i = 0; i < shortest; i++) {
    for (final b in blocks) {
      b.codewords[i] = raw[at++];
    }
  }
  for (final b in blocks) {
    if (b.dataCount > shortest) b.codewords[shortest] = raw[at++];
  }
  for (var i = 0; i < correctionPerBlock; i++) {
    for (final b in blocks) {
      b.codewords[b.dataCount + i] = raw[at++];
    }
  }

  return blocks;
}

// -----------------------------------------------------------------------------
// Stage 5: Reed-Solomon
// -----------------------------------------------------------------------------

/// Arithmetic in GF(256), the field the standard specifies.
///
/// Multiplication is addition of logarithms, so both tables are built once and
/// every later operation is a lookup. The exponent table is doubled in length
/// so a sum of two logarithms never needs a modulo.
class _Gf {
  static final Uint8List exp = Uint8List(512);
  static final Uint8List log = Uint8List(256);
  static var _ready = false;

  static void ensure() {
    if (_ready) return;
    _ready = true;
    var x = 1;
    for (var i = 0; i < 255; i++) {
      exp[i] = x;
      log[x] = i;
      x <<= 1;
      if (x & 0x100 != 0) x ^= 0x11D; // the field's primitive polynomial
    }
    for (var i = 255; i < 512; i++) {
      exp[i] = exp[i - 255];
    }
  }

  static int mul(int a, int b) =>
      (a == 0 || b == 0) ? 0 : exp[log[a] + log[b]];

  static int inv(int a) => exp[255 - log[a]];

  static int pow(int a, int n) => a == 0 ? 0 : exp[(log[a] * n) % 255];
}

/// Repair a block in place. False when the damage exceeds what the block can
/// carry, which is [correctionCount] / 2 wrong codewords.
///
/// Berlekamp-Massey finds the polynomial whose roots say *where* the errors
/// are, Chien search finds those roots, and Forney says *what* each error was.
bool _correct(Uint8List block, int correctionCount) {
  _Gf.ensure();
  final n = block.length;

  // Syndromes. The block is a polynomial with block[0] as the highest term,
  // and it is a valid codeword exactly when it vanishes at the first
  // `correctionCount` powers of the field generator.
  final syndromes = List<int>.filled(correctionCount, 0);
  var damaged = false;
  for (var i = 0; i < correctionCount; i++) {
    var s = 0;
    final at = _Gf.exp[i];
    for (var j = 0; j < n; j++) {
      s = _Gf.mul(s, at) ^ block[j];
    }
    syndromes[i] = s;
    if (s != 0) damaged = true;
  }
  if (!damaged) return true;

  // Berlekamp-Massey: find the shortest register that generates the syndromes.
  var lambda = <int>[1];
  var previous = <int>[1];
  var previousDiscrepancy = 1;
  var errors = 0;
  var shift = 1;

  for (var step = 0; step < correctionCount; step++) {
    var discrepancy = syndromes[step];
    for (var i = 1; i <= errors && i < lambda.length; i++) {
      discrepancy ^= _Gf.mul(lambda[i], syndromes[step - i]);
    }

    if (discrepancy == 0) {
      shift++;
      continue;
    }

    final before = List<int>.of(lambda);
    final scale = _Gf.mul(discrepancy, _Gf.inv(previousDiscrepancy));
    final needed = previous.length + shift;
    if (lambda.length < needed) {
      lambda.addAll(List<int>.filled(needed - lambda.length, 0));
    }
    for (var i = 0; i < previous.length; i++) {
      lambda[i + shift] ^= _Gf.mul(scale, previous[i]);
    }

    if (2 * errors <= step) {
      errors = step + 1 - errors;
      previous = before;
      previousDiscrepancy = discrepancy;
      shift = 1;
    } else {
      shift++;
    }
  }

  if (errors == 0 || errors > correctionCount ~/ 2) return false;

  // Chien search: a root at alpha^-i means codeword i is wrong.
  final positions = <int>[];
  for (var i = 0; i < n; i++) {
    final at = _Gf.exp[(255 - i % 255) % 255];
    var value = 0;
    for (var j = lambda.length - 1; j >= 0; j--) {
      value = _Gf.mul(value, at) ^ lambda[j];
    }
    if (value == 0) positions.add(i);
  }
  if (positions.length != errors) return false;

  // Forney: the magnitude of each error.
  final omega = List<int>.filled(correctionCount, 0);
  for (var i = 0; i < correctionCount; i++) {
    var s = 0;
    for (var j = 0; j <= i && j < lambda.length; j++) {
      s ^= _Gf.mul(syndromes[i - j], lambda[j]);
    }
    omega[i] = s;
  }

  for (final p in positions) {
    final at = _Gf.exp[(255 - p % 255) % 255];

    var numerator = 0;
    for (var j = omega.length - 1; j >= 0; j--) {
      numerator = _Gf.mul(numerator, at) ^ omega[j];
    }

    // The formal derivative over a field of characteristic two keeps only the
    // odd-numbered terms, because every even one doubles to zero.
    var denominator = 0;
    for (var j = 1; j < lambda.length; j += 2) {
      denominator ^= _Gf.mul(lambda[j], _Gf.pow(at, j - 1));
    }
    if (denominator == 0) return false;

    final magnitude =
        _Gf.mul(_Gf.exp[p % 255], _Gf.mul(numerator, _Gf.inv(denominator)));
    block[n - 1 - p] ^= magnitude;
  }

  // Recompute. Berlekamp-Massey can converge on a plausible answer for damage
  // beyond the block's capacity, and this is what catches that.
  for (var i = 0; i < correctionCount; i++) {
    var s = 0;
    final at = _Gf.exp[i];
    for (var j = 0; j < n; j++) {
      s = _Gf.mul(s, at) ^ block[j];
    }
    if (s != 0) return false;
  }

  return true;
}

// -----------------------------------------------------------------------------
// The bit stream
// -----------------------------------------------------------------------------

class _Bits {
  _Bits(this._bytes);
  final Uint8List _bytes;
  var _at = 0;

  int get remaining => _bytes.length * 8 - _at;

  int? read(int count) {
    if (count > remaining) return null;
    var value = 0;
    for (var i = 0; i < count; i++) {
      final byte = _bytes[_at >> 3];
      final bit = (byte >> (7 - (_at & 7))) & 1;
      value = (value << 1) | bit;
      _at++;
    }
    return value;
  }
}

const _alphanumeric = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

/// How many bits the character count takes, which the standard makes depend on
/// both the mode and how large the symbol is.
int _countBits(int mode, int version) {
  final band = version <= 9 ? 0 : (version <= 26 ? 1 : 2);
  return switch (mode) {
    1 => const [10, 12, 14][band],
    2 => const [9, 11, 13][band],
    4 => const [8, 16, 16][band],
    8 => const [8, 10, 12][band],
    _ => 0,
  };
}

/// Read mode segments until the terminator or the end of the data.
///
/// Byte segments are decoded as UTF-8 with a fallback to Latin-1. The standard
/// says Latin-1, and essentially every encoder in existence writes UTF-8
/// anyway, so trying the strict interpretation first and falling back is what
/// actually reads real codes.
String? _readSegments(Uint8List data, int version) {
  final bits = _Bits(data);
  final text = StringBuffer();
  final bytes = BytesBuilder();

  void flushBytes() {
    if (bytes.isEmpty) return;
    final raw = bytes.takeBytes();
    try {
      text.write(const Utf8Decoder(allowMalformed: false).convert(raw));
    } on FormatException {
      text.write(const Latin1Decoder().convert(raw));
    }
  }

  while (bits.remaining >= 4) {
    final mode = bits.read(4);
    if (mode == null || mode == 0) break;

    if (mode == 7) {
      // An ECI segment names a character set. The first byte gives the length
      // in a variable-length form; the assignment itself is ignored, since the
      // UTF-8 attempt above already covers what it would tell us.
      final first = bits.read(8);
      if (first == null) return null;
      if (first & 0x80 != 0 && bits.read(first & 0xC0 == 0xC0 ? 16 : 8) == null) {
        return null;
      }
      continue;
    }

    final countBits = _countBits(mode, version);
    if (countBits == 0) return null;
    final count = bits.read(countBits);
    if (count == null) return null;

    if (mode != 4) flushBytes();

    switch (mode) {
      case 1:
        var left = count;
        while (left >= 3) {
          final v = bits.read(10);
          if (v == null || v > 999) return null;
          text.write(v.toString().padLeft(3, '0'));
          left -= 3;
        }
        if (left == 2) {
          final v = bits.read(7);
          if (v == null || v > 99) return null;
          text.write(v.toString().padLeft(2, '0'));
        } else if (left == 1) {
          final v = bits.read(4);
          if (v == null || v > 9) return null;
          text.write(v.toString());
        }

      case 2:
        var left = count;
        while (left >= 2) {
          final v = bits.read(11);
          if (v == null || v >= 45 * 45) return null;
          text.write(_alphanumeric[v ~/ 45]);
          text.write(_alphanumeric[v % 45]);
          left -= 2;
        }
        if (left == 1) {
          final v = bits.read(6);
          if (v == null || v >= 45) return null;
          text.write(_alphanumeric[v]);
        }

      case 4:
        for (var i = 0; i < count; i++) {
          final v = bits.read(8);
          if (v == null) return null;
          bytes.addByte(v);
        }

      default:
        // Kanji and the structured-append and FNC1 headers. A pairing code is
        // never any of these, and guessing at a segment we cannot read would
        // return a corrupted string rather than nothing.
        return null;
    }
  }

  flushBytes();
  final out = text.toString();
  return out.isEmpty ? null : out;
}
