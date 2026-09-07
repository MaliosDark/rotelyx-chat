/// Saving a picture from the browser, which is a download.
///
/// The pixels are drawn onto a canvas and handed to the browser as a PNG, then
/// offered through a link that clicks itself. There is no permission involved:
/// a download is something the person asked for by pressing the button.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'save_photo_api.dart';

export 'save_photo_api.dart';

/// Every browser can download.
bool get canSavePhoto => true;

Future<void> savePhoto(Uint8List rgba, int width, int height,
    {String name = 'Rotelyx'}) async {
  final canvas = web.HTMLCanvasElement()
    ..width = width
    ..height = height;

  final context = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
  if (context == null) {
    throw const SaveRefused('This browser cannot prepare the picture.');
  }

  final clamped = Uint8ClampedList.fromList(rgba);
  final image = web.ImageData(clamped.toJS, width, height.toJS);
  context.putImageData(image, 0, 0);

  final url = canvas.toDataUrl('image/png');
  web.HTMLAnchorElement()
    ..href = url
    ..download = '$name.png'
    ..click();
}
