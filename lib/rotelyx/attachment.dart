/// Files, within the limits a blind mailbox imposes.
///
/// # Why attachments are small here
///
/// An envelope is padded to one of a fixed ladder of sizes, and the largest is
/// 8 MiB. That ceiling is not an oversight: a mailbox that accepts arbitrary
/// sizes leaks the size of what it carries, and one that accepts arbitrarily
/// large things is a file host with extra steps. The protocol repository says
/// so in as many words.
///
/// So a picture goes through, a video does not, and the app says which before
/// the user waits for an upload that will be refused.
///
/// # How one travels
///
/// As an ordinary MLS message whose body is a small header and base64 bytes.
/// There is no side channel and no second key: an attachment is exactly as
/// protected as the sentence next to it, which is the property worth having.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The ceiling, minus room for the header, MLS framing and base64's third.
///
/// Base64 inflates by 4/3, so the raw file must be well under the envelope
/// ceiling. Refusing early beats sealing something the mailbox will reject.
const int maxAttachmentBytes = 5 * 1024 * 1024;

/// What fits in one envelope without a capability token.
///
/// The mailbox allows 64 KiB in a free envelope. What travels is base64, which
/// is four bytes for every three, so the picture itself has 48 KiB before the
/// encoding alone overruns. Taking off the marker, the name, the type and what
/// MLS wraps around all of it leaves this, and it is deliberately a little
/// under: a deposit refused for being one byte over is a message somebody
/// watched fail for no reason they can see.
const int freeAttachmentBytes = 44 * 1024;

/// What an attachment should read as in one line.
///
/// Null when this body is not an attachment, so a caller can fall through to
/// showing the text.
///
/// # Why this exists
///
/// A conversation list and a notification both show the last thing said, and
/// both were showing the encoded attachment: `rx-file`, the filename, the
/// percent-escaped type and the first characters of the base64. It looked
/// like the application had broken.
///
/// The notification path meant to handle this and could not. It asked whether
/// the body was empty, which is true of a message that is only a picture in
/// some other design and is never true here: an attachment's body is the
/// marker and the bytes, which is a long way from empty.
String? attachmentSummary(String body) {
  final file = Attachment.decode(body);
  if (file == null) return null;

  // The kind rather than the filename, for a picture.
  //
  // A camera names a photograph `IMG_4812.HEIC` and a keyboard names a
  // sticker whatever it likes, and neither tells somebody glancing at a list
  // anything they wanted to know. A file keeps its name because the name is
  // the only thing that distinguishes one.
  // What was said with it, when something was. A line in a list that reads
  // "Picture" tells somebody less than the sentence that came with the
  // picture, which is what they would have read if they had opened it.
  if (file.caption.isNotEmpty) return file.caption;

  if (file.mime == 'image/gif') return 'GIF';
  if (file.isImage) return 'Picture';
  return file.name.isEmpty ? 'File' : file.name;
}

/// What an attachment is, from as much of one as there is.
///
/// A reply carries the first hundred and twenty characters of the message it
/// answers, so an attachment reaches a quote cut in half: the marker, the name,
/// usually the type, and none of the bytes. [attachmentSummary] refuses that,
/// correctly, because there is no attachment there -- and the quote then showed
/// a line of base64 where it should have said "Picture".
///
/// This reads the header and stops. It is for a label and never for content:
/// nothing here decodes bytes or hands back a file.
String? attachmentGlimpse(String body) {
  final whole = attachmentSummary(body);
  if (whole != null) return whole;
  if (!body.startsWith(_marker)) return null;

  final parts = body.substring(_marker.length).split('');
  String field(int i) {
    if (i >= parts.length) return '';
    try {
      return Uri.decodeComponent(parts[i]);
    } on Object {
      // The cut can land inside a percent escape.
      return parts[i];
    }
  }

  final mime = field(1);
  if (mime == 'image/gif') return 'GIF';
  if (mime.startsWith('image/')) return 'Picture';
  if (mime.startsWith('video/')) return 'Video';
  if (mime.startsWith('audio/')) return 'Audio';
  final name = field(0);
  return name.isEmpty ? 'File' : name;
}

/// A byte count somebody can read.
String readableBytes(int count) {
  final kb = count / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// Marks a message body as a file rather than text.
///
/// A prefix rather than a separate message type because the wasm's `send` takes
/// a string: adding a type would mean a parallel channel to keep in step.
const String _marker = 'rx-file';

class Attachment {
  const Attachment({
    required this.name,
    required this.mime,
    required this.bytes,
    this.caption = '',
  });

  final String name;
  final String mime;
  final Uint8List bytes;

  /// What was said along with it, in the same message.
  ///
  /// # Why it travels inside the attachment
  ///
  /// Sending a picture and then sending a line about it is two messages, two
  /// envelopes, two notifications and two bubbles, and on the other phone the
  /// line can arrive before the picture. Every messenger people already use
  /// sends one thing.
  ///
  /// It is a fourth field after the bytes rather than a new message type,
  /// which is what makes it safe to add: a build that has never heard of it
  /// splits on the separator, takes the first three fields and ignores the
  /// rest, so a captioned picture still shows as a picture on an older phone
  /// instead of failing to open. The bytes are base64 and cannot contain the
  /// separator, so the field after them is unambiguous.
  final String caption;

  bool get isImage => mime.startsWith('image/');

  String get readableSize => readableBytes(bytes.length);

  /// Pack for sending. The name is percent-encoded so a filename containing the
  /// separator cannot forge the header.
  String encode() => '$_marker'
      '${Uri.encodeComponent(name)}'
      '${Uri.encodeComponent(mime)}'
      '${base64Encode(bytes)}'
      '${caption.isEmpty ? '' : '${Uri.encodeComponent(caption)}'}';

  /// Null when [body] is ordinary text, which is the common case and must not
  /// cost an exception.
  ///
  /// # Why the result is remembered
  ///
  /// This is called from a bubble's `build`, and a transcript rebuilds on
  /// every keystroke in the composer, every message that arrives and every
  /// second a countdown ticks. Decoding forty kilobytes of base64 on each of
  /// those is work the frame cannot afford, and it is only the smaller half:
  /// each call produced a fresh `Uint8List`, the photo widget caches decoded
  /// pictures by the identity of their bytes, so every rebuild was a cache
  /// miss followed by a full decode of the picture on the UI thread. That is
  /// what made a chat with pictures in it stutter as it scrolled.
  ///
  /// Keyed by the body string, which is what the message stores and does not
  /// change, so the same message hands back the same bytes every time and
  /// everything downstream that caches by identity works.
  static Attachment? decode(String body) {
    if (!body.startsWith(_marker)) return null;
    final held = _parsed[body];
    if (held != null) return held;
    final parsed = _parse(body);
    if (parsed != null) {
      _parsed[body] = parsed;
      _parsedOrder.add(body);
      while (_parsedOrder.length > _keepParsed) {
        _parsed.remove(_parsedOrder.removeAt(0));
      }
    }
    return parsed;
  }

  /// Bounded: a transcript shows a few dozen attachments at most, and the
  /// bytes behind each are tens of kilobytes.
  static final Map<String, Attachment> _parsed = {};
  static final List<String> _parsedOrder = [];
  static const int _keepParsed = 64;

  static Attachment? _parse(String body) {
    final parts = body.substring(_marker.length).split('');
    if (parts.length < 3) return null;

    try {
      return Attachment(
        name: Uri.decodeComponent(parts[0]),
        mime: Uri.decodeComponent(parts[1]),
        bytes: base64Decode(parts[2]),
        // Absent in everything sent before captions existed, and in anything
        // sent by a build that does not have them.
        caption: parts.length > 3 ? Uri.decodeComponent(parts[3]) : '',
      );
    } on Object {
      return null;
    }
  }

  static bool looksLikeAttachment(String body) => body.startsWith(_marker);
}
