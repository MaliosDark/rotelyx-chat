/// A picture for a conversation, chosen and shrunk on this device.
///
/// # Why the picture is sent and never fetched
///
/// There is nowhere to fetch it from. No account, no directory, no server that
/// holds anything. So a picture travels the way a sentence does, through MLS,
/// as `Signal.profile`, and lives on the two devices that have it.
///
/// # Why it is shrunk before it goes anywhere
///
/// A photograph from a phone camera is four megabytes. An avatar is drawn at
/// forty pixels. Sending the original would mean an envelope a thousand times
/// larger than any message in the conversation, which is a shape the mailbox
/// operator can see from across the room: everything is padded to a uniform
/// size precisely so that one large thing does not stand out.
///
/// So it is decoded, cropped square, scaled to [_side] and re-encoded here.
/// What leaves is a few kilobytes, and what leaves is also *only* what was
/// scaled: re-encoding drops every piece of metadata the camera attached, which
/// on a phone photograph includes the place and time it was taken.
///
/// That last part is not a side effect worth being quiet about. Sending an
/// unmodified photograph as an avatar is one of the more common ways people
/// disclose where they live.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../platform/file_pick.dart';
import '../../rotelyx/gif_codec.dart';
import '../../rotelyx/photo_codec.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../../rotelyx/signal.dart';
import '../theme.dart';
import '../widgets.dart';

/// How wide the stored picture is, in pixels.
///
/// 256 rather than 40. The avatar is drawn small, but the same bytes are shown
/// beside a notification and in this sheet, and a picture scaled up from forty
/// pixels looks like a mistake on every screen made in the last decade.
const int _side = 256;

/// The most a picture may weigh once shrunk.
///
/// A bound rather than a hope. If a strange image encodes larger than this, it
/// is refused rather than sent, because the size of what leaves this device is
/// a property somebody is relying on.
const int _maxBytes = 96 * 1024;

/// Your own face, and a way to change it.
///
/// # What this is not
///
/// It used to sit on the contact card and write the *contact's* picture while
/// announcing the same bytes as yours. Two opposite things behind one button:
/// you set your own face and changed theirs, and their next profile signal
/// overwrote what you had set. It now writes [RotelyxStore.myPicture] and
/// nothing else, and a contact's face arrives from the contact.
///
/// [name] is only for the fallback, which is the initials avatar every build
/// already draws. Somebody who never chooses a picture is not missing one:
/// both ends draw the same face from the same name, with nothing travelling.
class PicturePicker extends StatefulWidget {
  const PicturePicker({
    super.key,
    required this.name,
    this.onChanged,
  });

  final String name;

  /// Told after a change, so a screen showing the same face can repaint.
  final VoidCallback? onChanged;

  @override
  State<PicturePicker> createState() => _PicturePickerState();
}

class _PicturePickerState extends State<PicturePicker> {
  bool _working = false;
  String? _problem;

  Future<void> _choose() async {
    setState(() {
      _working = true;
      _problem = null;
    });

    try {
      // A generous ceiling on the way in, because what matters is the size on
      // the way out and a large photograph shrinks to the same avatar as a
      // small one. Refusing a normal camera picture here would be absurd.
      // `images: true`, which this call was missing: without it the platform
      // opens a file browser, and somebody looking for a photograph is offered
      // documents.
      final picked = await pickFile(maxBytes: 24 * 1024 * 1024, images: true);
      if (picked == null) {
        if (mounted) setState(() => _working = false);
        return;
      }

      final shrunk = await shrinkToAvatar(picked.bytes);
      if (shrunk == null) {
        if (mounted) {
          setState(() {
            _working = false;
            _problem = 'That file is not an image this device can read.';
          });
        }
        return;
      }

      if (shrunk.length > _maxBytes) {
        if (mounted) {
          setState(() {
            _working = false;
            _problem = 'That image will not shrink small enough to send.';
          });
        }
        return;
      }

      store.myPicture = shrunk;

      // Sent as well as stored. A picture only this device knows about is a
      // picture the other side never sees, and the whole point of it is that
      // they do. Only the conversation that is live hears it here; the rest
      // are told as they are opened, by `RotelyxService`.
      rotelyx.signal(Signal.profile(shrunk));

      widget.onChanged?.call();
      if (mounted) setState(() => _working = false);
    } on NoFilePicker catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _problem = e.message;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _working = false;
          _problem = 'That image could not be read.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final picture = store.myPicture;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            SizedBox(
              width: 64,
              height: 64,
              child: picture == null
                  ? RxAvatar(widget.name, size: 64)
                  : ClipOval(
                      child: Image.memory(picture,
                          width: 64, height: 64, fit: BoxFit.cover)),
            ),
            Material(
              color: Tone.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _working ? null : _choose,
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: _working
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.photo_camera_outlined,
                          size: 14, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 150,
              child: Text(_problem!,
                  style: Type.small.copyWith(color: t.faint)),
            ),
          ),
      ],
    );
  }
}

/// Decode, crop square, scale, and re-encode.
///
/// Returns null when the bytes are not an image this platform can decode.
///
/// The crop is centred and takes the shorter side, which is what a person
/// expects from an avatar: a portrait becomes the middle of the portrait, not
/// the whole thing squashed.
///
/// Written with `dart:ui` rather than an image package, because the engine
/// already has a decoder for every format the platform supports and adding a
/// dependency to redo it in Dart would be slower and would support fewer.
/// Shrink a picture until it fits in [maxBytes], keeping its shape.
///
/// Returns the original when it already fits, null when the bytes are not a
/// picture this platform can decode or when even the smallest step is still
/// too big.
///
/// # Why this exists
///
/// A photograph off a modern phone is three to eight megabytes, and the
/// envelope ladder tops out where it does, so choosing a picture from a camera
/// roll was refused for being too large and the person was told to find a
/// smaller photograph. Nobody has a smaller photograph. Every messenger
/// shrinks on the way out and this one did it for avatars only.
///
/// Long edge rather than a square: an avatar is cropped because it is drawn in
/// a circle, and cropping somebody's photograph to fit a size limit would throw
/// away the part they were sending.
///
/// PNG because `toByteData` offers PNG and raw pixels and nothing else, and
/// adding an image package for JPEG would be the first dependency this
/// application has taken that it does not already need. The cost is real: PNG
/// of a photograph is several times a JPEG of the same picture, so the steps
/// below go further down than they would otherwise have to.
Future<Uint8List?> shrinkToFit(Uint8List bytes, {required int maxBytes}) async {
  if (bytes.length <= maxBytes) return bytes;

  ui.Image source;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    source = (await codec.getNextFrame()).image;
  } on Object {
    return null;
  }

  try {
    for (final edge in const [2048, 1600, 1280, 1024, 800, 640, 480]) {
      final longest =
          source.width > source.height ? source.width : source.height;
      // Never scale up: a small picture that is somehow over the limit is not
      // helped by being redrawn larger.
      if (edge >= longest && bytes.length > maxBytes && edge != 480) continue;

      final scale = edge / longest;
      final w = (source.width * scale).round().clamp(1, edge);
      final h = (source.height * scale).round().clamp(1, edge);

      final out = await _redraw(source, w, h);
      if (out != null && out.length <= maxBytes) return out;
    }
    return null;
  } finally {
    source.dispose();
  }
}

/// Draw [source] at [w] by [h] and encode it.
Future<Uint8List?> _redraw(ui.Image source, int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );

  final drawn = await recorder.endRecording().toImage(w, h);
  try {
    final data = await drawn.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    drawn.dispose();
  }
}

Future<Uint8List?> shrinkToAvatar(Uint8List bytes,
    {int side = _side, int maxBytes = _maxBytes}) async {
  ui.Image source;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    source = (await codec.getNextFrame()).image;
  } on Object {
    return null;
  }

  try {
    final short = source.width < source.height ? source.width : source.height;
    final left = (source.width - short) / 2;
    final top = (source.height - short) / 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(left, top, short.toDouble(), short.toDouble()),
      Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );

    final shrunk =
        await recorder.endRecording().toImage(side, side);
    try {
      // PNG first, because it is lossless and because a drawn avatar, a logo
      // or a letter on a flat ground is both smaller and sharper that way.
      final data = await shrunk.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      final png = data.buffer.asUint8List();
      if (png.length <= maxBytes) return png;

      // A photograph, which PNG is the wrong format for.
      //
      // `toByteData` offers PNG and raw pixels and nothing else, and a
      // photograph at 256 square is well over a hundred kilobytes losslessly.
      // So picking a face off a camera roll was refused, with a message that
      // told somebody to find a smaller photograph. Nobody has one.
      //
      // Down to a palette instead. `gif_codec.dart` is here for animations
      // and its quantiser does not care how many frames there are: one frame
      // is a still GIF, which every platform draws through `Image.memory`
      // without being told, including a build from before this existed. A
      // face at 256 colours is a few kilobytes and looks like the face.
      final pixels = await shrunk.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (pixels == null) return png;

      final frame = GifFrame(
        rgba: pixels.buffer.asUint8List(),
        width: side,
        height: side,
        delay: const Duration(milliseconds: 100),
      );

      for (final colours in const [256, 192, 128, 96, 64]) {
        final small = encodeGif([frame], colours: colours);
        if (small.length <= maxBytes) return small;
      }

      // Nothing fitted, which at this size should not happen. The PNG goes
      // back so the caller reports a size rather than a failure to decode.
      return png;
    } finally {
      shrunk.dispose();
    }
  } finally {
    source.dispose();
  }
}

/// Fit a photograph into a byte budget, as well as it can be fitted.
///
/// Returns null when the bytes are not a picture this platform can decode.
///
/// # Why this is not `shrinkToFit`
///
/// That one re-encodes as PNG, because `toByteData` offers PNG and raw pixels
/// and nothing else. PNG of a photograph is several times a lossy encoding of
/// the same picture, so meeting the free tier's 64 KiB envelope that way meant
/// drawing the photograph at around three hundred pixels on its long edge. That
/// is a stamp. `photo_codec.dart` exists so that it does not have to be.
///
/// # How the size is arrived at
///
/// Two dials and they are turned in the right order. Resolution comes down only
/// when quality alone cannot get there, because a smaller picture of the whole
/// scene beats a larger one that has been quantised into mush, and both beat
/// the picture being refused.
///
/// The search is a bisection on quality rather than a walk down a list of
/// steps, so it lands near the top of what the budget allows instead of at
/// whichever step happened to fit.
Future<Uint8List?> fitPicture(Uint8List bytes, {required int maxBytes}) async {
  ui.Image source;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    source = (await codec.getNextFrame()).image;
  } on Object {
    return null;
  }

  try {
    for (final edge in const [1600, 1280, 1024, 800, 640, 480, 360]) {
      final longest =
          source.width > source.height ? source.width : source.height;
      final scale = edge >= longest ? 1.0 : edge / longest;
      final w = (source.width * scale).round().clamp(8, 4096);
      final h = (source.height * scale).round().clamp(8, 4096);

      final rgba = await _pixels(source, w, h);
      if (rgba == null) return null;

      // Bisection between what is certainly too coarse to bother with and what
      // is as good as this codec is asked to go.
      var low = 12;
      var high = 92;
      Uint8List? best;

      while (low <= high) {
        final middle = (low + high) >> 1;
        final tried = encodePhoto(rgba, w, h, quality: middle);
        if (tried.length <= maxBytes) {
          best = tried;
          low = middle + 1;
        } else {
          high = middle - 1;
        }
      }

      if (best != null) return best;

      // Nothing fitted at this size. Down a step and try again, unless there
      // are no steps left, in which case this picture cannot be sent and
      // saying so is better than sending a smear.
      if (edge == 360) return null;
    }
    return null;
  } finally {
    source.dispose();
  }
}

/// Draw [source] at [w] by [h] and read the pixels back.
Future<Uint8List?> _pixels(ui.Image source, int w, int h) async {
  if (w == source.width && h == source.height) {
    final data = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data?.buffer.asUint8List();
  }

  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );

  final drawn = await recorder.endRecording().toImage(w, h);
  try {
    final data = await drawn.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data?.buffer.asUint8List();
  } finally {
    drawn.dispose();
  }
}

/// Fit an animation into a byte budget, and keep it animated.
///
/// Returns null when the bytes are not an animation this platform can decode,
/// or when even the last step is still too big.
///
/// # What is given up, and in what order
///
/// Frames first, then pixels, then colours. A dropped frame costs the least:
/// an animation at ten a second still reads as one, and a reaction GIF is
/// usually a second of loop. Pixels are next because a small animation is
/// still an animation. Colours are last because a palette under thirty two
/// starts to band, and banding is the one artefact people describe as broken
/// rather than as small.
///
/// Every combination is not tried. The steps go down together, which lands
/// slightly above the best possible file and takes a second rather than a
/// minute: re-encoding a GIF is the expensive part and each attempt pays it
/// again.
Future<Uint8List?> fitAnimation(Uint8List bytes,
    {required int maxBytes}) async {
  ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
  } on Object {
    return null;
  }

  if (codec.frameCount <= 1) return null;

  // Read once. Decoding is the slow half and the frames do not change between
  // attempts, only which of them are kept and how large they are drawn.
  final frames = <({ui.Image image, Duration delay})>[];
  try {
    for (var i = 0; i < codec.frameCount; i++) {
      final frame = await codec.getNextFrame();
      frames.add((image: frame.image, delay: frame.duration));
    }
  } on Object {
    for (final f in frames) {
      f.image.dispose();
    }
    return null;
  }

  try {
    // Keep every frame, then every other, and so on. A cap as well, because a
    // long animation with a modest budget cannot spend it on frames.
    // Measured rather than guessed. `tool/` has no harness for this, so the
    // rungs come from `test/gif_codec_test.dart`, which prints what each one
    // costs: at 128 colours a frame runs to about a tenth of a byte a pixel,
    // so 24 frames at 320 across is 170 KiB and 8 at 200 is 27.
    for (final (:keep, :edge, :colours) in const [
      (keep: 1, edge: 480, colours: 192),
      (keep: 1, edge: 320, colours: 128),
      (keep: 1, edge: 240, colours: 96),
      (keep: 2, edge: 240, colours: 96),
      (keep: 2, edge: 200, colours: 64),
      (keep: 3, edge: 180, colours: 64),
      (keep: 4, edge: 160, colours: 48),
      (keep: 5, edge: 128, colours: 32),
    ]) {
      final chosen = <({ui.Image image, Duration delay})>[];
      for (var i = 0; i < frames.length; i += keep) {
        chosen.add(frames[i]);
      }
      // Two frames is the floor. One is a still, and a still should have gone
      // through `fitPicture` and come out smaller and sharper.
      if (chosen.length < 2) continue;

      final first = chosen.first.image;
      final longest = first.width > first.height ? first.width : first.height;
      final scale = edge >= longest ? 1.0 : edge / longest;
      final w = (first.width * scale).round().clamp(8, 1024);
      final h = (first.height * scale).round().clamp(8, 1024);

      // Skip a rung that cannot fit, rather than paying for it to find out.
      //
      // Re-encoding is the expensive half and a phone pays it in whole
      // seconds. A tenth of a byte a pixel a frame is what the measurements
      // give, and half of that is a floor no rung has come near, so anything
      // over the budget at that rate is hopeless and is not attempted.
      if (chosen.length * w * h * 0.05 > maxBytes) continue;

      final out = <GifFrame>[];
      for (final frame in chosen) {
        final rgba = await _pixels(frame.image, w, h);
        if (rgba == null) return null;
        out.add(GifFrame(
          rgba: rgba,
          width: w,
          height: h,
          // The dropped frames' time is given to the one that replaces them,
          // so the animation runs at the speed it was made at rather than
          // sprinting through what is left.
          delay: frame.delay * keep,
        ));
      }

      final encoded = encodeGif(out, colours: colours);
      if (encoded.length <= maxBytes) return encoded;
    }
    return null;
  } finally {
    for (final f in frames) {
      f.image.dispose();
    }
  }
}
