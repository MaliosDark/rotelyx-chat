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

/// The avatar, and a way to change it.
class PicturePicker extends StatefulWidget {
  const PicturePicker({
    super.key,
    required this.conversation,
    required this.onPicked,
  });

  final StoredConversation conversation;
  final void Function(Uint8List? picture) onPicked;

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
      final picked = await pickFile(maxBytes: 24 * 1024 * 1024);
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

      widget.onPicked(shrunk);
      // Sent as well as stored. A picture only this device knows about is a
      // picture the other side never sees, and the whole point of it is that
      // they do.
      rotelyx.signal(Signal.profile(shrunk));
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
    final picture = widget.conversation.picture;

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
                  ? RxAvatar(widget.conversation.displayTitle, size: 64)
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
Future<Uint8List?> shrinkToAvatar(Uint8List bytes, {int side = _side}) async {
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
      // PNG because it is what `toByteData` offers and what every platform
      // decodes without argument. An avatar at this size is small either way.
      final data = await shrunk.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return data.buffer.asUint8List();
    } finally {
      shrunk.dispose();
    }
  } finally {
    source.dispose();
  }
}
