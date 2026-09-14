/// Fetching a file somebody linked to, and nothing else.
///
/// # Why this is a platform file
///
/// It is the one place in this application that opens a connection to an
/// address it was given rather than to the mailbox. Everything about it is a
/// deliberate exception, and an exception belongs somewhere it can be read in
/// one sitting: one function, one size limit, one timeout, two schemes.
///
/// Nothing here runs on its own. See `lib/rotelyx/media_link.dart` for what a
/// fetch reveals and why it never happens without somebody asking for it.
library;

import 'dart:typed_data';

/// What came back.
class Fetched {
  const Fetched({required this.bytes, required this.type});

  final Uint8List bytes;

  /// What the server said it is. Not trusted for anything but a label: what
  /// is drawn is decided by decoding the bytes.
  final String type;
}

/// The most that will be read, whatever the server says the length is.
///
/// A picture in a message is capped at 44 KiB because it travels in an
/// envelope. This does not travel, so it can be larger; it still has a ceiling,
/// because a link is written by somebody else and a stream with no end is a
/// way to fill this device's memory from a conversation.
const int fetchCeiling = 12 * 1024 * 1024;
