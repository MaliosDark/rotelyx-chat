/// Making an animation small enough to send, and keeping it an animation.
///
/// # Why this exists
///
/// A GIF used to arrive as one frame. It came in through the picture path,
/// which decodes with `dart:ui` and re-encodes with `photo_codec.dart`, and
/// both of those deal in a single image: the first one. What the other person
/// received was a still, and nothing said so.
///
/// The size is the other half. A reaction GIF off the internet is two hundred
/// kilobytes at the small end and two megabytes at the ordinary one, and one
/// envelope on the free tier holds forty four. So it has to come down, and the
/// only way down that keeps it moving is to give up frames, pixels and
/// colours rather than the animation itself.
///
/// # Why a GIF comes out rather than something better
///
/// GIF is a poor format. It is limited to 256 colours a frame and its
/// compression is from 1987. Everything about it is worse than the still codec
/// next door, which is why photographs do not go through here.
///
/// It wins on the one thing that matters at the far end: every platform draws
/// it, including a browser, and `Image.memory` animates it with no help. An
/// animation in a format of our own would need a player written three times
/// and would still be a still image on any build that had not been updated. A
/// smaller GIF is a GIF.
///
/// # What is given up, in order
///
/// Frames first, because a dropped frame costs the least: an animation at ten
/// a second reads as an animation. Then pixels, then colours, because a
/// palette below thirty two starts to band. Each is only spent when the one
/// before it has not been enough.
library;

import 'dart:typed_data';

/// Whether these bytes are a GIF, by their own header.
///
/// Checked here rather than trusting the type the picker gave, because a
/// picker on any platform will call a file whatever its extension says.
bool isGif(Uint8List bytes) =>
    bytes.length > 6 &&
    bytes[0] == 0x47 && // G
    bytes[1] == 0x49 && // I
    bytes[2] == 0x46 && // F
    bytes[3] == 0x38 && // 8
    (bytes[4] == 0x37 || bytes[4] == 0x39) && // 7 or 9
    bytes[5] == 0x61; // a

/// How big an animation is, without decoding it.
///
/// Null when the bytes are not a GIF. The logical screen size is bytes six to
/// nine of the header, least significant byte first, and it is there so that
/// a row can be the right height before the first frame exists. See
/// `photoSize` for why that matters.
({int width, int height})? gifSize(Uint8List bytes) {
  if (!isGif(bytes) || bytes.length < 10) return null;
  final width = bytes[6] | (bytes[7] << 8);
  final height = bytes[8] | (bytes[9] << 8);
  if (width <= 0 || height <= 0) return null;
  return (width: width, height: height);
}

/// One frame, as pixels and how long it stays.
class GifFrame {
  const GifFrame({
    required this.rgba,
    required this.width,
    required this.height,
    required this.delay,
  });

  final Uint8List rgba;
  final int width;
  final int height;

  /// How long this frame is shown. Never zero: a GIF that asks for no delay is
  /// asking every player to pick one, and they all pick differently.
  final Duration delay;
}

// ---------------------------------------------------------------------------
// Colour: choosing 256 of them, and saying which is nearest.
// ---------------------------------------------------------------------------

/// A palette built from the pixels that are actually in the picture.
///
/// Median cut rather than a fixed cube. A fixed palette spends colours on
/// parts of the spectrum a given animation never visits, and an animation is
/// usually a handful of hues: a cartoon, a face, a caption. Cutting the box
/// the actual colours occupy spends every entry on something that appears.
class _Palette {
  _Palette(this.colours);

  /// Packed 0xRRGGBB, at most 256 of them.
  final List<int> colours;

  /// Nearest entry, by squared distance, with a small cache.
  ///
  /// The cache is what makes this affordable: an animation has far fewer
  /// distinct colours than pixels, and the same ones recur every frame.
  final Map<int, int> _nearest = {};

  int indexOf(int rgb) {
    final held = _nearest[rgb];
    if (held != null) return held;

    final r = (rgb >> 16) & 0xFF;
    final g = (rgb >> 8) & 0xFF;
    final b = rgb & 0xFF;

    var best = 0;
    var bestDistance = 1 << 30;
    for (var i = 0; i < colours.length; i++) {
      final c = colours[i];
      final dr = ((c >> 16) & 0xFF) - r;
      final dg = ((c >> 8) & 0xFF) - g;
      final db = (c & 0xFF) - b;
      final distance = dr * dr + dg * dg + db * db;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
        if (distance == 0) break;
      }
    }

    // Bounded, because an animation with a lot of gradient would otherwise
    // grow a map the size of the picture.
    if (_nearest.length < 1 << 16) _nearest[rgb] = best;
    return best;
  }
}

/// Build a palette of at most [want] colours covering [pixels].
_Palette _palette(List<int> pixels, int want) {
  if (pixels.isEmpty) return _Palette([0]);

  // Boxes of colours, split repeatedly along whichever axis is widest, which
  // is the axis where a split separates the most.
  var boxes = <List<int>>[pixels];

  while (boxes.length < want) {
    // The box worth splitting is the one with the most in it that can still be
    // split. Splitting a box of one achieves nothing and loops forever.
    var widest = -1;
    var chosen = -1;
    for (var i = 0; i < boxes.length; i++) {
      if (boxes[i].length < 2) continue;
      if (boxes[i].length > widest) {
        widest = boxes[i].length;
        chosen = i;
      }
    }
    if (chosen < 0) break;

    final box = boxes[chosen];
    var rLow = 255, rHigh = 0, gLow = 255, gHigh = 0, bLow = 255, bHigh = 0;
    for (final c in box) {
      final r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
      if (r < rLow) rLow = r;
      if (r > rHigh) rHigh = r;
      if (g < gLow) gLow = g;
      if (g > gHigh) gHigh = g;
      if (b < bLow) bLow = b;
      if (b > bHigh) bHigh = b;
    }

    final rSpan = rHigh - rLow, gSpan = gHigh - gLow, bSpan = bHigh - bLow;
    final shift = rSpan >= gSpan && rSpan >= bSpan
        ? 16
        : gSpan >= bSpan
            ? 8
            : 0;

    box.sort((a, b) => ((a >> shift) & 0xFF).compareTo((b >> shift) & 0xFF));
    final middle = box.length >> 1;
    boxes
      ..removeAt(chosen)
      ..insert(chosen, box.sublist(0, middle))
      ..insert(chosen + 1, box.sublist(middle));
  }

  // One colour per box: the average of what is in it.
  final colours = <int>[];
  for (final box in boxes) {
    if (box.isEmpty) continue;
    var r = 0, g = 0, b = 0;
    for (final c in box) {
      r += (c >> 16) & 0xFF;
      g += (c >> 8) & 0xFF;
      b += c & 0xFF;
    }
    final n = box.length;
    colours.add(((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n));
  }
  if (colours.isEmpty) colours.add(0);
  return _Palette(colours);
}

// ---------------------------------------------------------------------------
// LZW, which is what a GIF is compressed with.
// ---------------------------------------------------------------------------

/// Bits, written least significant first, in blocks of at most 255 bytes.
///
/// The blocking is the format's, not a choice: a GIF's image data is a chain
/// of length-prefixed blocks ended by a zero.
class _Bits {
  final BytesBuilder _out = BytesBuilder(copy: false);
  final List<int> _block = [];
  int _bits = 0;
  int _count = 0;

  void write(int code, int width) {
    _bits |= code << _count;
    _count += width;
    while (_count >= 8) {
      _block.add(_bits & 0xFF);
      _bits >>= 8;
      _count -= 8;
      if (_block.length == 255) _flushBlock();
    }
  }

  void _flushBlock() {
    if (_block.isEmpty) return;
    _out.addByte(_block.length);
    _out.add(_block);
    _block.clear();
  }

  Uint8List finish() {
    if (_count > 0) {
      _block.add(_bits & 0xFF);
      _bits = 0;
      _count = 0;
    }
    _flushBlock();
    _out.addByte(0);
    return _out.takeBytes();
  }
}

/// Compress one frame's palette indices.
Uint8List _lzw(Uint8List indices, int minimumCodeSize) {
  final clear = 1 << minimumCodeSize;
  final end = clear + 1;

  var codeWidth = minimumCodeSize + 1;
  var next = end + 1;

  // Keyed by (prefix << 8) | byte, which is why the dictionary is a map rather
  // than a tree: a GIF's codes are at most twelve bits and the key fits an int
  // with room to spare.
  var table = <int, int>{};

  final bits = _Bits();
  bits.write(clear, codeWidth);

  if (indices.isEmpty) {
    bits.write(end, codeWidth);
    return bits.finish();
  }

  var prefix = indices[0];
  for (var i = 1; i < indices.length; i++) {
    final byte = indices[i];
    final key = (prefix << 8) | byte;
    final held = table[key];
    if (held != null) {
      prefix = held;
      continue;
    }

    bits.write(prefix, codeWidth);
    table[key] = next;
    next++;

    if (next > (1 << codeWidth)) {
      codeWidth++;
      // Twelve is the format's ceiling. Past it the dictionary is thrown away
      // and started again, which is what the clear code is for.
      if (codeWidth > 12) {
        bits.write(clear, 12);
        table = <int, int>{};
        codeWidth = minimumCodeSize + 1;
        next = end + 1;
      }
    }
    prefix = byte;
  }

  bits.write(prefix, codeWidth);
  bits.write(end, codeWidth);
  return bits.finish();
}

// ---------------------------------------------------------------------------
// Writing the file.
// ---------------------------------------------------------------------------

void _short(BytesBuilder out, int value) {
  out.addByte(value & 0xFF);
  out.addByte((value >> 8) & 0xFF);
}

/// Encode [frames] as one animated GIF, at [colours] colours.
///
/// Every frame is drawn whole, over the one before it. A GIF can describe a
/// frame as a patch of the previous one, which is smaller for an animation
/// where little moves, and it is not done here: working out the patch costs
/// more than it saves at these sizes, and getting the disposal rules wrong is
/// the commonest way to produce a file that plays differently in every viewer.
Uint8List encodeGif(List<GifFrame> frames, {int colours = 128}) {
  if (frames.isEmpty) return Uint8List(0);

  final width = frames.first.width;
  final height = frames.first.height;

  // One palette for the whole animation rather than one a frame.
  //
  // A local palette per frame would fit each better, and it costs up to 768
  // bytes every frame to say so. On a twelve frame animation that is nine
  // kilobytes of palette against a budget of forty four, which buys more than
  // the better fit gives back.
  final seen = <int>{};
  final sampled = <int>[];
  for (final frame in frames) {
    // Every fourth pixel. A palette is a summary and a quarter of a picture
    // summarises it as well as all of it, in a quarter of the time.
    for (var i = 0; i < frame.rgba.length; i += 16) {
      final rgb = (frame.rgba[i] << 16) |
          (frame.rgba[i + 1] << 8) |
          frame.rgba[i + 2];
      if (seen.add(rgb)) sampled.add(rgb);
    }
  }

  final want = colours.clamp(2, 256);
  final palette = _palette(sampled, want);

  // A GIF's palette is a power of two, and the size field is its log minus one.
  var entries = 2;
  var bitsPerEntry = 1;
  while (entries < palette.colours.length) {
    entries <<= 1;
    bitsPerEntry++;
  }

  final out = BytesBuilder(copy: false);
  out.add([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // GIF89a
  _short(out, width);
  _short(out, height);
  out.addByte(0x80 | (bitsPerEntry - 1)); // global table, its size
  out.addByte(0); // background index
  out.addByte(0); // pixel aspect ratio, unspecified

  for (var i = 0; i < entries; i++) {
    final c = i < palette.colours.length ? palette.colours[i] : 0;
    out.addByte((c >> 16) & 0xFF);
    out.addByte((c >> 8) & 0xFF);
    out.addByte(c & 0xFF);
  }

  // Loop forever. Netscape's extension, which is not a standard and is what
  // every player implements.
  out.add([0x21, 0xFF, 0x0B]);
  out.add('NETSCAPE2.0'.codeUnits);
  out.add([0x03, 0x01, 0x00, 0x00, 0x00]);

  for (final frame in frames) {
    // Hundredths of a second, which is the unit the format uses. Never zero:
    // a frame that asks for no delay is asking every player to choose one.
    final delay = (frame.delay.inMilliseconds ~/ 10).clamp(2, 0xFFFF);

    out.add([0x21, 0xF9, 0x04]);
    out.addByte(0); // no transparency, do not dispose
    _short(out, delay);
    out.addByte(0); // transparent index, unused
    out.addByte(0); // block terminator

    out.addByte(0x2C); // image descriptor
    _short(out, 0);
    _short(out, 0);
    _short(out, width);
    _short(out, height);
    out.addByte(0); // no local table, not interlaced

    final indices = Uint8List(width * height);
    for (var p = 0; p < indices.length; p++) {
      final i = p * 4;
      final rgb = (frame.rgba[i] << 16) |
          (frame.rgba[i + 1] << 8) |
          frame.rgba[i + 2];
      indices[p] = palette.indexOf(rgb);
    }

    // The format's floor is two bits, whatever the palette size.
    final minimumCodeSize = bitsPerEntry < 2 ? 2 : bitsPerEntry;
    out.addByte(minimumCodeSize);
    out.add(_lzw(indices, minimumCodeSize));
  }

  out.addByte(0x3B); // trailer
  return out.takeBytes();
}
