/// A picture somebody copied, waiting to be sent.
library;

import 'dart:typed_data';

/// What came off the clipboard.
class PastedImage {
  const PastedImage({required this.bytes, required this.mime});

  final Uint8List bytes;

  /// `image/gif` where it is one, because an animation that arrives as a
  /// still is the fault the picture path already had once.
  final String mime;
}
