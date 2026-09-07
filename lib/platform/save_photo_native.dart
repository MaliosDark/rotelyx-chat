/// Putting a picture into the phone's own library.
///
/// On iOS this is `ios/Runner/SaveToPhotos.swift`, which asks for the add-only
/// permission and nothing wider: the application may put one picture in and
/// cannot see, list or open anything that is already there. On Android it is
/// `MediaStore`, which on modern versions needs no permission at all for a
/// picture the application is inserting itself.
///
/// Elsewhere there is nowhere obvious to put it, and [canSavePhoto] says so
/// rather than the button being offered and then failing.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'save_photo_api.dart';

export 'save_photo_api.dart';

const MethodChannel _channel = MethodChannel('rotelyx/photos');

/// Whether this build has anywhere to put a picture.
bool get canSavePhoto => Platform.isIOS || Platform.isAndroid;

/// Save [rgba], which is four bytes a pixel, as a picture in the library.
///
/// Throws [SaveRefused] when the person said no or the write failed, with a
/// sentence that can be shown as it stands.
Future<void> savePhoto(Uint8List rgba, int width, int height,
    {String name = 'Rotelyx'}) async {
  if (!canSavePhoto) {
    throw const SaveRefused('Saving pictures is not built for this platform.');
  }

  try {
    await _channel.invokeMethod<void>('save', {
      'bytes': rgba,
      'width': width,
      'height': height,
      'name': name,
    });
  } on PlatformException catch (e) {
    throw SaveRefused(switch (e.code) {
      'refused' => 'Rotelyx is not allowed to add pictures. You can turn that '
          'on in Settings, under Photos.',
      'undecodable' => 'That picture could not be prepared for saving.',
      _ => e.message ?? 'That picture could not be saved.',
    });
  } on MissingPluginException {
    throw const SaveRefused('This build cannot save pictures yet.');
  }
}
