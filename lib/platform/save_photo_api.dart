/// Keeping a copy of a picture that arrived.
///
/// # Why this takes pixels rather than the file
///
/// What arrives is `photo_codec.dart`'s format, which nothing outside this
/// application can read. Handing those bytes to a photo library would store a
/// file that the Photos application opens as a broken image, which is worse
/// than not offering to save at all. So the picture is decoded first and what
/// crosses this boundary is the pixels.
library;

/// What went wrong, in words meant for a person.
class SaveRefused implements Exception {
  const SaveRefused(this.message);

  final String message;

  @override
  String toString() => message;
}
