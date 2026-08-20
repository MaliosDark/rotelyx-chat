/// What a chosen file looks like, whichever platform chose it.
library;

import 'dart:typed_data';

class PickedFile {
  const PickedFile({required this.name, required this.mime, required this.bytes});

  final String name;
  final String mime;
  final Uint8List bytes;

  int get size => bytes.length;
}

/// Why no file came back, when the reason is worth telling the user.
class NoFilePicker implements Exception {
  const NoFilePicker(this.message);
  final String message;
  @override
  String toString() => message;
}
