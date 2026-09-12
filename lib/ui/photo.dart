/// Showing a picture that arrived in this application's own codec.
///
/// `Image.memory` cannot: the bytes are not a format the engine knows, which is
/// the whole point of them. So they are decoded here, handed to the engine as
/// pixels, and drawn as any other image would be.
///
/// The decode is cached by identity, because a transcript rebuilds on every
/// message, every keystroke in the composer and every second that a countdown
/// ticks, and doing the inverse transform of a thousand blocks each time would
/// make the whole screen stutter.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../platform/save_photo.dart';
import '../rotelyx/attachment.dart';
import '../rotelyx/gif_codec.dart';
import '../rotelyx/photo_codec.dart';
import 'theme.dart';

/// Decoded pictures, keyed by the bytes they came from.
///
/// Bounded. The oldest is dropped rather than the map growing for the life of
/// the application, because these are bitmaps and a bitmap is several
/// megabytes whatever the file it came from weighed. Thirty two is enough
/// that scrolling back through a screenful of pictures does not decode them
/// again, and at a few megabytes each is still under what a phone gives one
/// application.
///
/// Keyed by the identity of the bytes, which only works because the bytes for
/// one message are the same object every time: `Attachment.decode` remembers
/// what it parsed. When it did not, every rebuild missed here and decoded the
/// picture again on the UI thread, and that is what made scrolling stutter.
final Map<Uint8List, ui.Image> _decoded = <Uint8List, ui.Image>{};
final List<Uint8List> _order = <Uint8List>[];
const int _keep = 32;

void _remember(Uint8List key, ui.Image image) {
  _decoded[key] = image;
  _order.add(key);
  while (_order.length > _keep) {
    final oldest = _order.removeAt(0);
    _decoded.remove(oldest)?.dispose();
  }
}

/// Draws one of this application's pictures.
///
/// Falls back to the ordinary decoder when the bytes are not one of ours, so
/// the same widget shows a picture sent by an older build.
class RotelyxPhoto extends StatefulWidget {
  const RotelyxPhoto({
    super.key,
    required this.bytes,
    this.fit = BoxFit.cover,
    this.onFailed,
  });

  final Uint8List bytes;
  final BoxFit fit;

  /// What to draw when this is not a picture at all.
  final WidgetBuilder? onFailed;

  @override
  State<RotelyxPhoto> createState() => _RotelyxPhotoState();
}

class _RotelyxPhotoState extends State<RotelyxPhoto> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RotelyxPhoto old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) _load();
  }

  Future<void> _load() async {
    final held = _decoded[widget.bytes];
    if (held != null) {
      setState(() => _image = held);
      return;
    }

    // Off the UI thread.
    //
    // The decoder is pure Dart and the inverse transform of a picture's
    // blocks takes tens of milliseconds, which is more than a frame. Run
    // where the frame is being drawn, every picture scrolling into view cost
    // a dropped frame or several, and a chat with pictures in it stuttered
    // exactly while somebody was scrolling it. An isolate costs copying the
    // bytes in and the pixels out, and neither is anywhere near a frame.
    //
    // The bytes are checked first so that text that is not a picture at all
    // is answered here without spinning anything up.
    if (!isRotelyxPhoto(widget.bytes)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final DecodedPhoto? decoded;
    try {
      decoded = await compute(decodePhoto, widget.bytes);
    } on Object {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (decoded == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) return;

    final buffer = await ui.ImmutableBuffer.fromUint8List(decoded.rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: decoded.width,
      height: decoded.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();

    if (!mounted) {
      frame.image.dispose();
      return;
    }
    _remember(widget.bytes, frame.image);
    setState(() => _image = frame.image);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      // Not ours: an animation, or a PNG from an older build. Still drawn,
      // and still in the right shape while it decodes where the format says
      // what that is.
      final image = Image.memory(
        widget.bytes,
        fit: widget.fit,
        errorBuilder: (context, _, __) =>
            widget.onFailed?.call(context) ?? const SizedBox.shrink(),
      );

      final size = gifSize(widget.bytes);
      if (size == null) return image;
      return AspectRatio(
        aspectRatio: size.width / size.height,
        child: image,
      );
    }

    final image = _image;
    if (image == null) {
      // The right shape before there is anything to draw.
      //
      // A transcript scrolls to the bottom one frame after a message arrives,
      // and a picture is not decoded by then. A guessed shape meant the row
      // changed height underneath the scroll that had already happened, and
      // the picture ended up above the fold, which on a picture is most of
      // it. The size is in the header of both formats and reading it costs
      // nothing, so the row is right from the first frame and nothing moves.
      final size = photoSize(widget.bytes) ?? gifSize(widget.bytes);
      return AspectRatio(
        aspectRatio: size == null ? 4 / 3 : size.width / size.height,
        child: Container(color: Colors.black.withValues(alpha: 0.18)),
      );
    }

    // Its own layer. A still picture does not change while the list around
    // it scrolls, and without a boundary it is rasterised again with every
    // frame the list moves. See the notes at the top of the file.
    return RepaintBoundary(
      child: RawImage(image: image, fit: widget.fit),
    );
  }
}

/// A picture on its own, over everything else.
///
/// Pinch and drag to look closer, a way to keep it, and a way out. Opened by
/// tapping the picture in the transcript, because a photograph inside a bubble
/// is a thumbnail whatever its resolution and looking properly at one is the
/// ordinary thing to want.
class PhotoViewer extends StatelessWidget {
  const PhotoViewer({super.key, required this.file, this.onSave});

  final Attachment file;

  /// Keeping a copy. Null where this build cannot write one, in which case the
  /// button is not offered rather than offered and broken.
  final Future<void> Function()? onSave;

  static Future<void> open(
    BuildContext context, {
    required Attachment file,
    Future<void> Function()? onSave,
  }) {
    final messenger = ScaffoldMessenger.of(context);

    // Saving is offered only where there is somewhere to put it, and only for
    // pictures this application can decode. A button that appears and then
    // says it cannot is worse than no button.
    Future<void> keep() async {
      final decoded = decodePhoto(file.bytes);
      if (decoded == null) {
        messenger.showSnackBar(
            const SnackBar(content: Text('That picture cannot be saved.')));
        return;
      }
      try {
        await savePhoto(decoded.rgba, decoded.width, decoded.height,
            name: file.name.split('.').first);
        messenger.showSnackBar(
            const SnackBar(content: Text('Saved to your pictures.')));
      } on SaveRefused catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    }

    return Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      pageBuilder: (_, __, ___) => PhotoViewer(
        file: file,
        onSave: onSave ??
            (canSavePhoto && isRotelyxPhoto(file.bytes) ? keep : null),
      ),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // The picture, and anywhere else on the screen closes it. A tap
          // outside is what everybody tries first.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: InteractiveViewer(
                maxScale: 8,
                child: Center(
                  child: RotelyxPhoto(bytes: file.bytes, fit: BoxFit.contain),
                ),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                    Expanded(
                      child: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.label.copyWith(color: Colors.white),
                      ),
                    ),
                    if (onSave != null)
                      IconButton(
                        onPressed: onSave,
                        tooltip: 'Save a copy',
                        icon: const Icon(Icons.download_outlined,
                            color: Colors.white),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
