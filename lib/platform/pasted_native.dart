/// Offering a picture somebody copied.
///
/// # Why this is how stickers arrive
///
/// An iPhone has no API for its stickers. Memoji, the packs an application
/// brings, and whatever GIF keyboard somebody installed are the keyboard's
/// business: it hands them to a text field as rich content, a Flutter text
/// field is plain text and drops them, and Flutter's own hook for keyboard
/// content is Android only.
///
/// So on iOS the route is the one every keyboard already supports. The person
/// copies, and this offers to send it. No third party is called and nothing
/// is searched: the only thing this application sees is the one picture that
/// was put on the clipboard.
///
/// On Android the keyboard hands content straight to the field, so this is
/// the second way rather than the only one.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'pasted_api.dart';

export 'pasted_api.dart';

const MethodChannel _channel = MethodChannel('rotelyx/clipboard');

/// Whether there is a picture worth offering.
///
/// Deliberately separate from reading it. Reading raises the banner iOS shows
/// when an application looks at the clipboard; asking does not, because the
/// answer is given without handing the contents over. So the offer is made
/// from the cheap question and the bytes are taken only once somebody has
/// tapped it.
Future<bool> hasPastedImage() async {
  if (!Platform.isIOS) return false;
  try {
    return await _channel.invokeMethod<bool>('has') ?? false;
  } on Object {
    return false;
  }
}

/// Take it, now that somebody has asked for it.
Future<PastedImage?> pastedImage() async {
  if (!Platform.isIOS) return null;
  try {
    final row = await _channel.invokeMethod<Map<Object?, Object?>>('read');
    if (row == null) return null;
    final bytes = row['bytes'];
    if (bytes is! Uint8List) return null;
    return PastedImage(
      bytes: bytes,
      mime: row['mime'] as String? ?? 'image/png',
    );
  } on Object {
    return null;
  }
}
