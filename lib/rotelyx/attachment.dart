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
  });

  final String name;
  final String mime;
  final Uint8List bytes;

  bool get isImage => mime.startsWith('image/');

  String get readableSize {
    final kb = bytes.length / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  /// Pack for sending. The name is percent-encoded so a filename containing the
  /// separator cannot forge the header.
  String encode() => '$_marker'
      '${Uri.encodeComponent(name)}'
      '${Uri.encodeComponent(mime)}'
      '${base64Encode(bytes)}';

  /// Null when [body] is ordinary text, which is the common case and must not
  /// cost an exception.
  static Attachment? decode(String body) {
    if (!body.startsWith(_marker)) return null;

    final parts = body.substring(_marker.length).split('');
    if (parts.length < 3) return null;

    try {
      return Attachment(
        name: Uri.decodeComponent(parts[0]),
        mime: Uri.decodeComponent(parts[1]),
        bytes: base64Decode(parts[2]),
      );
    } on Object {
      return null;
    }
  }

  static bool looksLikeAttachment(String body) => body.startsWith(_marker);
}
