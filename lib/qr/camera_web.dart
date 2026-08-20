/// The camera, reached directly rather than through a plugin.
///
/// # What this replaces
///
/// The usual answer is a scanner package. Every one of them that supports the
/// web loads a JavaScript decoder from a content delivery network the first
/// time the camera opens. The Content-Security-Policy in `web/index.html`
/// blocks that, which is the policy working: this app is supposed to contact
/// nothing but its own mailbox.
///
/// The browser already exposes everything needed. `getUserMedia` gives a video
/// stream, a canvas turns a frame into pixels, and `lib/qr/detect.dart` reads
/// the code out of them. No package, no download, no exception in the policy.
///
/// # Where the frames go
///
/// Nowhere. A frame is drawn into an off-screen canvas, reduced to brightness,
/// examined, and overwritten by the next one. It is never encoded, never
/// stored, and never sent. The camera stops the moment the screen closes,
/// which is also when the browser's recording indicator goes out.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'package:flutter/widgets.dart';

import 'camera_api.dart';
import 'decode.dart';
import 'detect.dart';

export 'camera_api.dart';

/// A running camera, and the frames it produces.
class CameraFeed {
  CameraFeed._(this._stream, this._video, this._canvas, this._context,
      this.viewType, this._width, this._height);

  final web.MediaStream _stream;
  final web.HTMLVideoElement _video;
  final web.HTMLCanvasElement _canvas;
  final web.CanvasRenderingContext2D _context;

  /// The identifier to give `HtmlElementView` so Flutter shows the preview.
  final String viewType;

  final int _width;
  final int _height;

  static var _nextView = 0;

  /// Ask for the camera and start it.
  ///
  /// [analyse] caps the size of the frame that gets examined. The preview can
  /// be as sharp as the device likes; the decoder does not benefit from more
  /// than about five hundred pixels across, and every extra pixel is work done
  /// on every frame.
  static Future<CameraFeed> open({int analyse = 512}) async {
    final devices = web.window.navigator.mediaDevices;
    // ignore: unnecessary_null_comparison
    if (devices == null) {
      throw const CameraDenied(CameraProblem.insecure, 'no mediaDevices');
    }

    final wanted = JSObject();
    // The rear camera where there is a choice, since that is the one pointed
    // at the other person's screen. `ideal` rather than `exact` so a laptop
    // with only a front camera still works instead of failing outright.
    wanted['facingMode'] = 'environment'.toJS;
    wanted['width'] = (1280).toJS;
    wanted['height'] = (720).toJS;

    final web.MediaStream stream;
    try {
      stream = await devices
          .getUserMedia(
              web.MediaStreamConstraints(video: wanted, audio: false.toJS))
          .toDart;
    } on Object catch (e) {
      throw CameraDenied(_classify('$e'), '$e');
    }

    final video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..srcObject = stream;
    // Without this, iOS Safari takes the stream fullscreen instead of showing
    // it in place, which puts the preview over the whole app.
    video.setAttribute('playsinline', 'true');
    video.setAttribute('muted', 'true');
    video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'cover';

    try {
      await video.play().toDart;
    } on Object {
      // Some browsers reject the promise and play anyway. Whether frames
      // actually arrive is decided below, not here.
    }

    // The stream reports its size asynchronously. Reading it too early gives
    // zero, and a zero-sized canvas silently returns blank frames forever.
    final ready = await _waitForFrames(video);
    if (!ready) {
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }
      throw const CameraDenied(
          CameraProblem.missing, 'the camera produced no frames');
    }

    final scale = analyse / (video.videoWidth > video.videoHeight
        ? video.videoWidth
        : video.videoHeight);
    final width = scale < 1 ? (video.videoWidth * scale).round() : video.videoWidth;
    final height =
        scale < 1 ? (video.videoHeight * scale).round() : video.videoHeight;

    final canvas = web.HTMLCanvasElement()
      ..width = width
      ..height = height;
    final context = canvas.getContext('2d') as web.CanvasRenderingContext2D;

    final viewType = 'rotelyx-camera-${_nextView++}';
    ui_web.platformViewRegistry
        .registerViewFactory(viewType, (int _) => video);

    return CameraFeed._(
        stream, video, canvas, context, viewType, width, height);
  }

  static Future<bool> _waitForFrames(web.HTMLVideoElement video) async {
    for (var attempt = 0; attempt < 60; attempt++) {
      if (video.videoWidth > 0 && video.videoHeight > 0) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  static CameraProblem _classify(String error) {
    final text = error.toLowerCase();
    if (text.contains('notallowed') || text.contains('permission')) {
      return CameraProblem.refused;
    }
    if (text.contains('notfound') || text.contains('devicesnotfound')) {
      return CameraProblem.missing;
    }
    if (text.contains('notreadable') || text.contains('trackstart')) {
      return CameraProblem.missing;
    }
    if (text.contains('secure') || text.contains('undefined')) {
      return CameraProblem.insecure;
    }
    return CameraProblem.unknown;
  }

  /// Take the current frame and look for a code in it.
  ///
  /// Returns null far more often than not, which is normal: it means this
  /// particular frame had no readable code in it.
  /// The preview, as a widget.
  ///
  /// The browser's own video element, placed into the Flutter tree. Given the
  /// same name as the phone's so `lib/ui/screens/scan.dart` can render a camera
  /// without knowing which platform produced it.
  Widget preview() => HtmlElementView(viewType: viewType);

  QrResult? read() {
    if (_video.readyState < 2) return null;

    _context.drawImage(_video, 0, 0, _width.toDouble(), _height.toDouble());
    final data = _context.getImageData(0, 0, _width, _height).data.toDart;
    return scan(Luma.fromRgba(_width, _height, Uint8List.view(data.buffer)));
  }

  /// Stop the camera and release it.
  ///
  /// Called from `dispose`, and it matters: a stream left running keeps the
  /// recording indicator lit and the camera unavailable to everything else.
  void close() {
    for (final track in _stream.getTracks().toDart) {
      track.stop();
    }
    _video.srcObject = null;
    _canvas.width = 0;
    _canvas.height = 0;
  }
}

/// Run a camera and report codes as they are seen.
///
/// Reading is deliberately paced rather than tied to the display refresh. A
/// code that is in front of the lens stays there for a second or more, so
/// examining eight frames a second finds it just as fast as sixty would and
/// leaves the processor alone the rest of the time.
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
      _timer = Timer.periodic(const Duration(milliseconds: 125), (_) {
        if (_busy) return;
        _busy = true;
        try {
          final result = feed.read();
          if (result != null) onFound(result.text);
        } on Object {
          // A frame that cannot be read is not worth stopping the camera for.
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
