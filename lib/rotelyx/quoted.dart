/// Replying to a particular message.
///
/// # Why the quote travels with the reply
///
/// There is no message id on the wire. That is deliberate: an id is a handle
/// the mailbox could use to correlate one envelope with another, and the whole
/// addressing design exists to stop exactly that.
///
/// So a reply carries a short copy of what it answers rather than a pointer to
/// it. That costs a few dozen bytes inside an envelope that was going to be
/// padded to a fixed size anyway, so on the wire it usually costs nothing at
/// all, and it means a reply still makes sense on a device that never received
/// the message being answered.
///
/// # The shape
///
/// The same trick attachments use: a marker, then fields, then the body. The
/// engine's `send` takes a string, and adding a real message type would mean a
/// parallel channel to keep in step with the protocol repository.
///
/// A message that is not a reply is unchanged, so an older build shows the
/// whole thing as text rather than losing it. That is the reason for a prefix
/// rather than a length-prefixed frame.
library;

/// Marks a message body as a reply.
const String _marker = 'rx-reply';

/// Field separator: unit separator, which no keyboard produces.
const String _sep = '\x1f';

/// How much of the quoted message travels.
///
/// Enough to recognise, short enough not to resend a paragraph. A quote is a
/// reminder of what is being answered, not a copy of it.
const int quoteLimit = 120;

class Quoted {
  const Quoted({
    required this.author,
    required this.excerpt,
    required this.reply,
  });

  /// Who wrote the message being answered. Their claimed label, as everywhere.
  final String author;

  /// The opening of that message, trimmed to [quoteLimit].
  final String excerpt;

  /// What is actually being said now.
  final String reply;

  /// Wrap for sending.
  String encode() {
    // Separators are stripped rather than escaped. They cannot be typed, so the
    // only way one appears is a paste of something strange, and dropping it is
    // better than a body a decoder could misread.
    String clean(String s) => s.replaceAll(_sep, ' ');
    final short = excerpt.length > quoteLimit
        ? '${excerpt.substring(0, quoteLimit).trimRight()}...'
        : excerpt;
    return [_marker, clean(author), clean(short), clean(reply)].join(_sep);
  }

  /// Read one back, or null when this is an ordinary message.
  static Quoted? decode(String body) {
    if (!body.startsWith('$_marker$_sep')) return null;
    final parts = body.split(_sep);
    if (parts.length < 4) return null;
    return Quoted(
      author: parts[1],
      excerpt: parts[2],
      // Anything after the third separator belongs to the reply, so a body that
      // somehow contains one is not truncated.
      reply: parts.sublist(3).join(_sep),
    );
  }

  /// What to show where only one line fits, such as the conversation list.
  static String plain(String body) => decode(body)?.reply ?? body;
}
