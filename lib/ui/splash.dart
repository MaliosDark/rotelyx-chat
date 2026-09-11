/// The mark assembling itself, once, while the application is already running.
///
/// # Why this is drawn and not played
///
/// The study in `docs/brand/rotelyx-motion.html` renders to a 1.6 MB GIF. The
/// geometry it renders *from* is 534 bytes: three paths. So the three paths are
/// here, and the motion is the one that study calls 01, Magnetic assembly, with
/// the same offsets and the same easing.
///
/// # Why it cannot make the application slower
///
/// It is drawn **over** a running application, not in front of one that is
/// waiting. Nothing awaits it, nothing is gated on it, and the screen beneath
/// is live and built the whole time. If somebody taps through it, they are
/// tapping a real screen.
///
/// It is also shorter than the study: 1100 ms against 2800. A page for choosing
/// between six ideas can take its time; a thing somebody sees every time they
/// open a messenger cannot.
library;

import 'package:flutter/material.dart';

import 'widgets.dart';

/// The three pieces, as `docs/brand/rotelyx-motion.svg` draws them.
///
/// Written out rather than parsed. It is three paths of five commands, and a
/// path parser would be more code than the paths, with somewhere for a bug to
/// live that this has not.
Path _outer() => Path()
  ..moveTo(98, 110)
  ..lineTo(319, 110)
  ..cubicTo(369, 110, 406, 148, 406, 196)
  ..cubicTo(406, 244, 366, 284, 312, 284)
  ..lineTo(309, 284)
  ..lineTo(414, 410)
  ..lineTo(363, 410)
  ..lineTo(226, 248)
  ..lineTo(313, 248)
  ..cubicTo(339, 248, 359, 226, 359, 198)
  ..cubicTo(359, 172, 340, 153, 319, 153)
  ..lineTo(137, 153)
  ..close();

Path _user() => Path()
  ..moveTo(176, 192)
  ..lineTo(272, 192)
  ..lineTo(312, 241)
  ..lineTo(218, 241)
  ..close();

Path _relay() => Path()
  ..moveTo(170, 230)
  ..lineTo(253, 325)
  ..lineTo(170, 408)
  ..close();

/// Where each piece comes in from, and when it lands.
///
/// Taken from the study, which is why the numbers are not round: the outer
/// piece swings in from the upper right, and the two smaller ones arrive from
/// the lower left, later and turning further, so the mark reads as being built
/// rather than as three things fading in together.
class _Piece {
  const _Piece({
    required this.path,
    required this.colour,
    required this.from,
    required this.turn,
    required this.shrink,
    required this.start,
    required this.end,
  });

  final Path Function() path;
  final Color colour;
  final Offset from;

  /// Degrees.
  final double turn;
  final double shrink;

  /// As a fraction of the whole, so changing the duration keeps the rhythm.
  final double start;
  final double end;
}

const _violet = Color(0xFF722CF5);
const _bone = Color(0xFFFAFAFA);

const _pieces = <_Piece>[
  _Piece(
    path: _outer,
    colour: _bone,
    from: Offset(100, -65),
    turn: 22,
    shrink: 0.82,
    start: 0.10,
    end: 0.62,
  ),
  _Piece(
    path: _user,
    colour: _bone,
    from: Offset(-85, 90),
    turn: -65,
    shrink: 0.70,
    start: 0.20,
    end: 0.70,
  ),
  _Piece(
    path: _relay,
    colour: _violet,
    from: Offset(-100, 70),
    turn: -130,
    shrink: 0.70,
    start: 0.30,
    end: 0.78,
  ),
];

/// The easing the study uses throughout: a long, decelerating arrival.
const _ease = Cubic(0.16, 1, 0.3, 1);

/// The mark, at some point between scattered and assembled.
class RotelyxMark extends StatelessWidget {
  const RotelyxMark({super.key, required this.t, this.size = 132});

  /// 0 is scattered and unlit, 1 is the finished mark.
  final double t;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _MarkPainter(t)),
      );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    // The paths are drawn in the 512 square the study uses, so everything is
    // scaled once here rather than every number being divided by hand.
    canvas.save();
    canvas.scale(size.width / 512, size.height / 512);

    for (final piece in _pieces) {
      final span = piece.end - piece.start;
      final raw = span <= 0 ? 1.0 : (t - piece.start) / span;
      final p = _ease.transform(raw.clamp(0.0, 1.0));

      if (p <= 0) continue;

      final path = piece.path();
      // Turned and scaled about its own middle, so a piece rotates in place
      // rather than swinging around a corner of the canvas.
      final centre = path.getBounds().center;

      canvas.save();
      canvas.translate(
        piece.from.dx * (1 - p),
        piece.from.dy * (1 - p),
      );
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(piece.turn * (1 - p) * 3.1415926535897932 / 180);
      final scale = piece.shrink + (1 - piece.shrink) * p;
      canvas.scale(scale);
      canvas.translate(-centre.dx, -centre.dy);

      canvas.drawPath(
        path,
        Paint()
          ..color = piece.colour.withValues(alpha: p)
          ..isAntiAlias = true,
      );
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.t != t;
}

/// How long the whole thing takes.
const _assemble = Duration(milliseconds: 1100);

/// And how long it takes to get out of the way afterwards.
const _leave = Duration(milliseconds: 260);

/// Draws [child], with the mark assembling over it once and then leaving.
///
/// The child is built and live from the first frame. This only covers it.
class Splash extends StatefulWidget {
  const Splash({super.key, required this.child});

  final Widget child;

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    duration: _assemble,
  );

  /// Painted over the child until it has gone, then not built at all.
  bool _showing = true;

  /// Started once, from `didChangeDependencies` and not from `initState`.
  ///
  /// Reading `MediaQuery` is asking an inherited widget, and `initState` runs
  /// before this element may depend on one: Flutter asserts, and the assertion
  /// takes the first screen of the application with it. `didChangeDependencies`
  /// is the first place that lookup is allowed, and it runs more than once, so
  /// it is guarded.
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _run.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _showing = false);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    // Somebody who has asked their phone for less movement gets the mark and
    // not the assembly, which is the whole of the accommodation: the screen
    // still says what it says, it simply does not move to say it.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _run.value = 1;
      setState(() => _showing = false);
    } else {
      _run.forward();
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showing) return widget.child;

    return Stack(
      children: [
        widget.child,
        // Taps go to the screen underneath, because it is a real screen and
        // there is no reason for a picture to eat somebody's first tap.
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _showing ? 1 : 0,
            duration: _leave,
            child: ColoredBox(
              // The theme's own ground, so the mark sits on the colour the
              // application is about to be rather than on a second one that
              // flashes as it leaves.
              color: RotelyxThemeScope.of(context).backdrop,
              child: Center(
                child: AnimatedBuilder(
                  animation: _run,
                  builder: (_, __) => RotelyxMark(t: _run.value),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
