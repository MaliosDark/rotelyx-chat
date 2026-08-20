/// Pointing the camera at somebody else's code.
///
/// # What is on screen, and what is happening underneath
///
/// The preview is the camera's own video element, placed into the Flutter tree
/// as a platform view. Flutter draws over it, not through it, which is why the
/// viewfinder is a frame around the preview rather than a hole punched in a
/// dimmed layer.
///
/// Eight times a second a frame is copied into an off-screen canvas, reduced to
/// brightness, and examined by `lib/qr/detect.dart`. Nothing is uploaded, and
/// nothing is kept: each frame is overwritten by the next, and the camera stops
/// the instant this screen closes.
///
/// # Why there is always a way out
///
/// Cameras fail for reasons the user cannot fix from inside the app. Permission
/// was refused once and the browser remembers. The laptop has no camera. The
/// page is not on https, so the browser will not hand one over at all. In every
/// one of those cases the code can still be typed, so the field is always there
/// rather than appearing as a consolation after something breaks.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../qr/camera.dart';
import '../../rotelyx/meeting_code.dart';
import '../theme.dart';
import '../widgets.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  /// Open the scanner and wait for a meeting code, or null if the user backed
  /// out.
  static Future<String?> open(BuildContext context) =>
      Navigator.of(context).push<String>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const ScanScreen(),
      ));

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _typed = TextEditingController();

  QrCameraScanner? _scanner;
  CameraDenied? _problem;
  String? _sawSomethingElse;
  var _starting = true;
  var _done = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    final scanner = QrCameraScanner(
      onFound: _sighted,
      onFailure: (problem) {
        if (mounted) setState(() { _problem = problem; _starting = false; });
      },
    );
    _scanner = scanner;
    await scanner.start();
    if (mounted && _problem == null) setState(() => _starting = false);
  }

  /// A QR was read. Whether it was one of ours is a separate question.
  void _sighted(String text) {
    if (_done) return;

    final code = readMeetingCode(text);
    if (code == null) {
      // Some other QR wandered into frame. Say so instead of ignoring it, or
      // the user is left holding a code at a screen that does nothing.
      final shown = text.length > 42 ? '${text.substring(0, 42)}...' : text;
      if (mounted && _sawSomethingElse != shown) {
        setState(() => _sawSomethingElse = shown);
      }
      return;
    }

    _done = true;
    _scanner?.stop();
    HapticFeedback.mediumImpact();
    if (mounted) Navigator.of(context).pop(code);
  }

  void _acceptTyped() {
    final code = readMeetingCode(_typed.text);
    if (code == null) {
      setState(() => _sawSomethingElse =
          'that does not look like a meeting code');
      return;
    }
    _done = true;
    _scanner?.stop();
    Navigator.of(context).pop(code);
  }

  @override
  void dispose() {
    _scanner?.stop();
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Scaffold(
      backgroundColor: t.backdrop,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Metrics.wide),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.close, size: 20, color: t.muted),
                    ),
                  ),
                  const SizedBox(height: Metrics.gap),
                  Text('Scan their code',
                      style: Type.display.copyWith(color: t.text)),
                  const SizedBox(height: 6),
                  Text(
                    'Point the camera at the code on the other person\'s '
                    'screen. It reads by itself, there is nothing to press.',
                    style: Type.body.copyWith(color: t.muted),
                  ),
                  const SizedBox(height: Metrics.wide),

                  _viewfinder(t),

                  if (_sawSomethingElse != null) ...[
                    const SizedBox(height: Metrics.pad),
                    RxNote(
                      'Read: $_sawSomethingElse\n\n'
                      'That is a QR code, but not a Rotelyx meeting code. A '
                      'Rotelyx code begins with $meetingPrefix.',
                      tone: Tone.warn,
                      title: 'Not one of ours',
                    ),
                  ],

                  const SizedBox(height: Metrics.wide),
                  Row(children: [
                    Expanded(child: Divider(color: t.line)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('or type it',
                          style: Type.small.copyWith(color: t.faint)),
                    ),
                    Expanded(child: Divider(color: t.line)),
                  ]),
                  const SizedBox(height: Metrics.pad),
                  RxField(
                    controller: _typed,
                    hint: '$meetingPrefix ABCD EFGH ...',
                    onSubmit: (_) => _acceptTyped(),
                    help: 'Spaces and capitals do not matter. A code can be '
                        'read aloud down a phone line just as well as scanned.',
                  ),
                  const SizedBox(height: Metrics.gap),
                  RxButton('Use this code',
                      weight: Weight.secondary,
                      wide: true,
                      onTap: _acceptTyped),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewfinder(RotelyxTheme t) {
    final problem = _problem;

    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(Metrics.radius + 4),
          border: Border.all(color: t.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (problem != null)
              _failure(t, problem)
            else if (_starting)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Tone.accent)),
                    const SizedBox(height: Metrics.pad),
                    Text('Asking for the camera',
                        style: Type.small.copyWith(color: t.muted)),
                  ],
                ),
              )
            else if (_scanner?.feed != null)
              // Whatever this platform's camera renders as: a video element in
              // a browser, a texture on a phone. The screen does not know.
              _scanner!.feed!.preview(),

            if (problem == null && !_starting) ...[
              const _Brackets(),
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(Metrics.pill),
                    ),
                    child: Text('Looking',
                        style: Type.small.copyWith(color: Colors.white)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _failure(RotelyxTheme t, CameraDenied problem) => Padding(
        padding: const EdgeInsets.all(Metrics.wide),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off_outlined, size: 30, color: t.faint),
              const SizedBox(height: Metrics.pad),
              Text(
                problem.message,
                textAlign: TextAlign.center,
                style: Type.small.copyWith(color: t.muted),
              ),
              const SizedBox(height: Metrics.pad),
              Text('You can still type the code below.',
                  textAlign: TextAlign.center,
                  style: Type.small.copyWith(color: t.faint)),
            ],
          ),
        ),
      );
}

/// Four corner brackets, marking where to aim.
///
/// A frame rather than a dimmed overlay with a hole in it: the decoder looks at
/// the whole frame, so pretending only the middle counts would be a lie the
/// user would then act on by holding the phone closer than necessary.
class _Brackets extends StatelessWidget {
  const _Brackets();

  @override
  Widget build(BuildContext context) =>
      const IgnorePointer(child: CustomPaint(painter: _BracketPainter()));
}

class _BracketPainter extends CustomPainter {
  const _BracketPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.shortestSide * 0.14;
    final arm = size.shortestSide * 0.12;
    const radius = 14.0;

    final paint = Paint()
      ..color = Colors.white.withOpacity(0.85)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final left = inset;
    final top = inset;
    final right = size.width - inset;
    final bottom = size.height - inset;

    void bracket(double x, double y, double dx, double dy) {
      final path = Path()
        ..moveTo(x, y + dy * (arm + radius))
        ..lineTo(x, y + dy * radius)
        ..quadraticBezierTo(x, y, x + dx * radius, y)
        ..lineTo(x + dx * (arm + radius), y);
      canvas.drawPath(path, paint);
    }

    bracket(left, top, 1, 1);
    bracket(right, top, -1, 1);
    bracket(left, bottom, 1, -1);
    bracket(right, bottom, -1, -1);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
