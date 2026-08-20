/// Choosing a file on a phone, through the system picker.
///
/// # What this asks for, and what it deliberately does not
///
/// Nothing. There is no `READ_MEDIA_IMAGES` and no storage permission at all.
/// The system draws the picker, the person chooses one file, and this process
/// is handed that one file. Everything else on the device stays invisible.
///
/// The alternative, asking to read every image on the phone so that a gallery
/// can be drawn inside this application, is what most messengers do. It buys a
/// prettier picker and it costs a line on the permission screen that a person
/// has no way to tell apart from "this application can see all your photographs
/// whenever it likes", because that is what it says.
///
/// The work is in `android/.../FilePicker.kt`. iOS is not wired up and reports
/// so rather than throwing something unreadable.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'file_pick_api.dart';

export 'file_pick_api.dart';

const MethodChannel _channel = MethodChannel('rotelyx/files');

Future<PickedFile?> pickFile({int? maxBytes}) async {
  if (!Platform.isAndroid) {
    throw const NoFilePicker(
        'Choosing a file is not built for this platform yet.');
  }

  final Map<Object?, Object?>? picked;
  try {
    picked = await _channel.invokeMethod<Map<Object?, Object?>>(
        'pick', {'maxBytes': maxBytes});
  } on PlatformException catch (e) {
    throw NoFilePicker(switch (e.code) {
      'toolarge' => e.message ?? 'That file is too large to send.',
      'nopicker' => 'This device has no file picker.',
      'busy' => 'A file picker is already open.',
      _ => e.message ?? 'That file could not be read.',
    });
  } on MissingPluginException {
    throw const NoFilePicker(
        'This build has no file picker. Rebuild the Android app.');
  }

  // Null is "chose nothing", which is a thing people do and is not a failure.
  if (picked == null) return null;

  final bytes = picked['bytes'];
  if (bytes is! Uint8List) return null;

  return PickedFile(
    name: picked['name'] as String? ?? 'attachment',
    mime: picked['mime'] as String? ?? 'application/octet-stream',
    bytes: bytes,
  );
}
