/// The camera on a phone, feeding the decoder in `lib/qr/`.
///
/// # What this is and is not
///
/// It is a wire. The work is split in two and neither half is here: the frames
/// come from `android/.../QrCamera.kt`, and the reading is done by `scan()` in
/// `detect.dart`, which was already complete and already tested against every
/// version and correction level, against damage up to the correction budget,
/// and against a photograph taken at an angle in poor light.
///
/// This file connects them, and that is the whole of what was missing. The
/// decoder had been usable from a browser since it was written and could not be
/// reached from the platform the application is actually for.
///
/// # Why frames are asked for rather than pushed
///
/// A camera produces about thirty frames a second and a decode takes longer
/// than the gap between two of them. Pushing every frame across the platform
/// channel would send thirty and throw away twenty five, having paid to copy
/// each one. So the newest frame is held on the Android side and this asks for
/// one when it has finished with the last, which also means the interval below
/// is a floor and not a promise.
library;

import 'dart:async';


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_api.dart';
import 'decode.dart';
import 'detect.dart';

export 'camera_api.dart';

const MethodChannel _channel = MethodChannel('rotelyx/camera');

/// An open camera.
class CameraFeed {
  CameraFeed._(this._texture, this.width, this.height);

  final int _texture;

  /// What the camera was asked for. The frames say what they actually are, and
  /// these are only used to size the preview before the first one arrives.
  final int width;
  final int height;

  /// The preview, as a widget.
  ///
  /// A `Texture` rather than a platform view: the camera writes into a surface
  /// Flutter owns, so the preview composites with everything drawn over it
  /// instead of punching a hole through the layer tree. The overlay the scanner
  /// screen draws on top would not be possible with a platform view.
  Widget preview() => Texture(textureId: _texture, filterQuality: FilterQuality.low);

  static Future<CameraFeed> open() async {
    final permitted = await _invoke<bool>('permit') ?? false;
    if (!permitted) {
      throw const CameraDenied(CameraProblem.refused,
          'the camera permission was refused');
    }

    final Map<Object?, Object?>? opened;
    try {
      opened = await _channel.invokeMethod<Map<Object?, Object?>>('start');
    } on PlatformException catch (e) {
      throw CameraDenied(
        e.code == 'already' ? CameraProblem.unknown : CameraProblem.missing,
        e.message ?? 'the camera would not open',
      );
    } on MissingPluginException {
      throw const CameraDenied(CameraProblem.unbuilt,
          'this build has no camera channel');
    }

    if (opened == null) {
      throw const CameraDenied(
          CameraProblem.missing, 'the camera reported nothing');
    }

    return CameraFeed._(
      opened['texture'] as int? ?? 0,
      opened['width'] as int? ?? 0,
      opened['height'] as int? ?? 0,
    );
  }

  /// Read the newest frame, or null when none has arrived or none decodes.
  ///
  /// Asynchronous, unlike the browser's, which reads a canvas it already owns.
  /// Crossing a platform channel is not something to pretend is free.
  Future<QrResult?> read() async {
    final frame = await _invoke<Map<Object?, Object?>>('frame');
    if (frame == null) return null;

    final bytes = frame['bytes'];
    final width = frame['width'] as int? ?? 0;
    final height = frame['height'] as int? ?? 0;
    if (bytes is! Uint8List || width <= 0 || height <= 0) return null;
    if (bytes.length < width * height) return null;

    return scan(Luma(width, height, bytes));
  }

  void close() {
    unawaited(_invoke<void>('stop'));
  }

  static Future<T?> _invoke<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Opens the camera and watches it until something is found or it is stopped.
///
/// The same shape as the browser's, so `lib/ui/screens/scan.dart` does not know
/// which one it has.
class QrCameraScanner {
  QrCameraScanner({required this.onFound, required this.onFailure});

  final void Function(String text) onFound;
  final void Function(CameraDenied problem) onFailure;

  CameraFeed? _feed;
  Timer? _timer;
  var _stopped = false;
  var _busy = false;

  CameraFeed? get feed => _feed;

  Future<void> start() async {
    try {
      final feed = await CameraFeed.open();
      if (_stopped) {
        feed.close();
        return;
      }
      _feed = feed;

      _timer = Timer.periodic(const Duration(milliseconds: 120), (_) async {
        // A tick that arrives while the last decode is still running is
        // dropped rather than queued. Queueing them means the backlog grows
        // for as long as the code is out of frame, and every one of those
        // decodes runs against a frame that is no longer what the camera sees.
        if (_busy || _stopped) return;
        _busy = true;
        try {
          final result = await feed.read();
          if (result != null && !_stopped) onFound(result.text);
        } on Object {
          // A frame that will not read is the ordinary case, not a fault: it
          // is what every frame with no code in it does.
        } finally {
          _busy = false;
        }
      });
    } on CameraDenied catch (problem) {
      if (!_stopped) onFailure(problem);
    }
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _feed?.close();
    _feed = null;
  }
}
