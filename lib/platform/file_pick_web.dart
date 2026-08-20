/// A file chosen through the browser's own picker.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_pick_api.dart';

export 'file_pick_api.dart';

/// Show the picker and read what was chosen.
///
/// Returns null when the user closed it without choosing, which is not a
/// failure and should not be reported as one. Throws [NoFilePicker] only when
/// the file could not be read.
Future<PickedFile?> pickFile({int? maxBytes}) async {
  final input = web.HTMLInputElement()..type = 'file';
  input.click();

  await input.onChange.first;
  final file = input.files?.item(0);
  if (file == null) return null;

  if (maxBytes != null && file.size > maxBytes) {
    throw NoFilePicker('that file is ${(file.size / 1024 / 1024).toStringAsFixed(1)} MB');
  }

  // `package:web` exposes no typed onLoad stream for FileReader on this SDK,
  // so the callback is bridged to a Future by hand.
  final done = Completer<ByteBuffer?>();
  final reader = web.FileReader();
  reader.onload = ((web.Event _) {
    final result = reader.result;
    done.complete(result.isA<JSArrayBuffer>() ? (result! as JSArrayBuffer).toDart : null);
  }).toJS;
  reader.onerror = ((web.Event _) => done.complete(null)).toJS;
  reader.readAsArrayBuffer(file);

  final buffer = await done.future;
  if (buffer == null) throw const NoFilePicker('that file could not be read');

  return PickedFile(
    name: file.name,
    mime: file.type.isEmpty ? 'application/octet-stream' : file.type,
    bytes: buffer.asUint8List(),
  );
}
