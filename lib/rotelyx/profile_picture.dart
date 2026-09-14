/// A profile picture, between the PNG the screens draw and the small thing
/// that travels.
///
/// The screens, the notification icons and the settings sheet all draw a PNG,
/// because that is what the platform decodes. The wire carries the
/// application's own picture format, because a 256 pixel PNG of a face is two
/// to three times the envelope the free tier allows and was arriving nowhere.
/// These two functions are the crossing, one each way.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'photo_codec.dart';

/// The PNG chosen in settings, as it goes on the wire, or null when it will
/// not fit (see [encodeProfileForTheWire]).
Future<Uint8List?> profileForTheWire(Uint8List png) async {
  final ui.Image image;
  try {
    final codec = await ui.instantiateImageCodec(png);
    image = (await codec.getNextFrame()).image;
  } on Object {
    return null;
  }
  try {
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    return encodeProfileForTheWire(
        rgba.buffer.asUint8List(), image.width, image.height);
  } finally {
    image.dispose();
  }
}

/// What arrived on the wire, as the PNG everything on this device draws.
Future<Uint8List?> pngOfRotelyxPhoto(Uint8List bytes) async {
  final decoded = decodePhoto(bytes);
  if (decoded == null) return null;
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    decoded.rgba,
    decoded.width,
    decoded.height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  final image = await done.future;
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
