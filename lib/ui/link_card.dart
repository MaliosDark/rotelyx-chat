/// A link to a file, drawn as the file it points at.
///
/// The argument for this, and the rule that nothing is fetched until somebody
/// asks, is in `lib/rotelyx/media_link.dart`. This is the part on the screen.
///
/// Three states, and they are all one card so nothing jumps as it moves
/// between them: waiting to be asked, fetching, and showing. A picture and an
/// animation end up inside the bubble; a track shows its cover and its title;
/// a video says what it is and hands the link to the player on the phone,
/// because playing video would mean a decoder in the messenger and this
/// application does not have one and should not.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../platform/fetch.dart';
import '../platform/share.dart';
import '../rotelyx/attachment.dart';
import '../rotelyx/media_link.dart';
import '../rotelyx/track_tags.dart';
import 'photo.dart';
import 'theme.dart';

class LinkCard extends StatefulWidget {
  const LinkCard({super.key, required this.link, required this.fg});

  final MediaLink link;

  /// The colour the bubble writes in, so the card belongs to the bubble rather
  /// than sitting in it.
  final Color fg;

  @override
  State<LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends State<LinkCard> {
  /// What has been fetched, once somebody asked.
  Uint8List? _bytes;
  TrackTags? _tags;
  bool _busy = false;
  String? _failed;

  /// Fetched once per card per run, and remembered for as long as the
  /// conversation is open.
  ///
  /// Keyed by the link, so scrolling a picture off the screen and back does
  /// not ask the host for it again -- which would be a second visit from this
  /// address, and a second line in somebody's log.
  static final Map<String, Uint8List> _held = {};
  static final List<String> _order = [];
  static const int _keep = 12;

  @override
  void initState() {
    super.initState();
    final held = _held[widget.link.url];
    if (held != null) {
      _bytes = held;
      if (widget.link.kind == LinkKind.audio) _tags = readTrackTags(held);
    }
  }

  Future<void> _get() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = null;
    });

    final got = await fetchLinked(widget.link.url);
    if (!mounted) return;

    if (got == null || got.bytes.isEmpty) {
      setState(() {
        _busy = false;
        _failed = 'That would not load.';
      });
      return;
    }

    _held[widget.link.url] = got.bytes;
    _order.add(widget.link.url);
    while (_order.length > _keep) {
      _held.remove(_order.removeAt(0));
    }

    setState(() {
      _bytes = got.bytes;
      _busy = false;
      if (widget.link.kind == LinkKind.audio) _tags = readTrackTags(got.bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;

    if (bytes != null && widget.link.isPicture) return _picture(bytes);
    if (bytes != null && widget.link.kind == LinkKind.audio) {
      return _track(bytes);
    }
    return _ask(context);
  }

  Widget _picture(Uint8List bytes) => GestureDetector(
        onTap: () => PhotoViewer.open(
          context,
          file: Attachment(
            name: widget.link.name,
            mime: widget.link.kind == LinkKind.animation
                ? 'image/gif'
                : 'image/jpeg',
            bytes: bytes,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: RotelyxPhoto(
            bytes: bytes,
            onFailed: (_) => _row(
              icon: Icons.broken_image_outlined,
              title: widget.link.name,
              detail: 'That is not a picture this device can read.',
            ),
          ),
        ),
      );

  /// A track: its cover, its title, and the phone's own player for the sound.
  Widget _track(Uint8List bytes) {
    final tags = _tags ?? const TrackTags();
    final cover = tags.cover;

    return GestureDetector(
      onTap: () => openLink(widget.link.url),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: widget.fg.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 52,
                height: 52,
                child: cover == null
                    ? Container(
                        color: widget.fg.withValues(alpha: 0.10),
                        child: Icon(Icons.music_note,
                            size: 24, color: widget.fg.withValues(alpha: 0.7)),
                      )
                    : RotelyxPhoto(
                        bytes: cover,
                        onFailed: (_) => Icon(Icons.music_note,
                            size: 24, color: widget.fg.withValues(alpha: 0.7)),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      tags.title.isEmpty ? widget.link.name : tags.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.label.copyWith(color: widget.fg)),
                  if (tags.artist.isNotEmpty)
                    Text(tags.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.small.copyWith(
                            color: widget.fg.withValues(alpha: 0.7))),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow,
                          size: 14, color: widget.fg.withValues(alpha: 0.7)),
                      const SizedBox(width: 2),
                      Text('Play on this phone',
                          style: Type.small.copyWith(
                              fontSize: 11,
                              color: widget.fg.withValues(alpha: 0.7))),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Before anything has been fetched: what it is, and what a tap costs.
  Widget _ask(BuildContext context) {
    final link = widget.link;
    final video = link.kind == LinkKind.video;

    return GestureDetector(
      onTap: _busy
          ? null
          : video
              // Video is never fetched here: the phone's player streams it,
              // which is better at it and does not put twelve megabytes
              // through this application to do it.
              ? () => openLink(link.url)
              : _get,
      child: _row(
        icon: switch (link.kind) {
          LinkKind.picture => Icons.image_outlined,
          LinkKind.animation => Icons.gif_box_outlined,
          LinkKind.video => Icons.play_circle_outline,
          LinkKind.audio => Icons.music_note_outlined,
        },
        title: link.name,
        detail: _failed ??
            (_busy
                ? 'Loading…'
                : video
                    ? 'Tap to play it. ${link.host} will see this device.'
                    : 'Tap to show it. ${link.host} will see this device.'),
        busy: _busy,
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String detail,
    bool busy = false,
  }) =>
      Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: widget.fg.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: busy
                  ? Padding(
                      padding: const EdgeInsets.all(2),
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: widget.fg.withValues(alpha: 0.7)),
                    )
                  : Icon(icon, size: 22, color: widget.fg.withValues(alpha: 0.8)),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.label.copyWith(color: widget.fg)),
                  Text(detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.small.copyWith(
                          fontSize: 11.5,
                          color: widget.fg.withValues(alpha: 0.62))),
                ],
              ),
            ),
          ],
        ),
      );
}
