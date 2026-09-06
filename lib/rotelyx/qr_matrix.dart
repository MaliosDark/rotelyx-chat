/// A QR symbol as the squares it is made of, rather than as a picture.
///
/// # Why a matrix travels instead of an image
///
/// The watch has to draw the same code the phone would have drawn. It could be
/// sent a PNG, and then two encoders exist: this one and whatever the watch
/// uses, differing in version, mask and error correction, and a code that reads
/// on one screen and not the other is a bug nobody can reproduce.
///
/// So the phone encodes once: the same library, the same level, the same
/// symbol the pairing screen shows, and sends the rows. The watch paints
/// squares. At version 4 that is 33 rows of 33 characters, about a kilobyte,
/// which is nothing across a link that already carries message text.
///
/// It is also the smaller attack surface: an image is decoded by an image
/// decoder, and a string of noughts and ones is not.
library;

import 'package:qr/qr.dart';

/// The modules of the QR symbol for [data], one string per row, `1` for a dark
/// module and `0` for a light one.
///
/// Error correction H, matching `RxQrCode` in `lib/ui/brand.dart`. It is the
/// highest of the four levels and it is what lets the mark sit in the middle of
/// the symbol without breaking it, and on a watch, what lets a scanner cope
/// with a small curved screen held at an angle.
List<String> qrRows(String data) {
  final image = QrImage(QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.H,
  ));

  return [
    for (var row = 0; row < image.moduleCount; row++)
      String.fromCharCodes([
        for (var col = 0; col < image.moduleCount; col++)
          image.isDark(row, col) ? 0x31 : 0x30,
      ]),
  ];
}
