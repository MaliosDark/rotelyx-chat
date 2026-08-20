/// Watching a message burn.
///
/// # Why this exists at all
///
/// Every other surface in this application is deliberately quiet: a messenger
/// that flashes at people is a messenger that is hard to read. This is the
/// exception, and the reason is that a disappearing message is the one moment
/// where the user needs to *believe* something happened. A message that simply
/// blinks out could have been hidden. One that is consumed cannot.
///
/// # How it is drawn
///
/// Two passes over the same noise field, from `shaders/burn.frag`:
///
///   1. A mask, applied to the bubble with `BlendMode.dstIn`, so the bubble
///      itself is eaten away along a front that comes down from the top.
///   2. The fire, painted over the top in the band just inside that front.
///   3. Embers, thrown off the front and drifting up across the conversation.
///
/// One shader and one field, so the flame is always exactly on the tear rather
/// than near it.
///
/// # Why the embers need a bigger canvas
///
/// They leave the bubble, which means the layer that draws them cannot be the
/// size of the bubble. It is given room above and to the sides with an
/// `OverflowBox`, and the shader is told where the bubble sits inside that
/// larger area so it knows where the sparks come from.
///
/// # It burns downwards
///
/// A message is read from the top, so consuming it from the top takes the words
/// in the order they were read. The first attempt spread outward from a point
/// near the bottom and the result was described, accurately, as a crazy fire
/// coming in from the side.
///
/// # If the shader will not load
///
/// It falls back to a fade. A device with no shader support, or a build that
/// somehow shipped without the asset, should lose the spectacle and keep the
/// behaviour: the message still goes.
library;

import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// How long a message takes to burn.
///
/// A second and a half: long enough to watch, short enough not to be in the way
/// of a conversation. `--dart-define=slowBurn=true` stretches it to twelve
/// seconds, which exists only so a still photograph can be taken of the middle
/// of it. `adb exec-out screencap` takes about a second, so at the real speed
/// every frame lands either side of the flame.
const Duration _burnDuration = bool.fromEnvironment('slowBurn')
    ? Duration(seconds: 12)
    : Duration(milliseconds: 1450);

/// Loads the program once for the whole application.
///
/// `FragmentProgram.fromAsset` reads and compiles, which is not something to do
/// per message. Compiled on first use rather than at startup, because most
/// sessions never burn anything.
class BurnShader {
  BurnShader._();

  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram?>? _loading;
  static bool _failed = false;

  static Future<ui.FragmentProgram?> load() {
    if (_program != null) return Future.value(_program);
    if (_failed) return Future.value(null);
    return _loading ??= ui.FragmentProgram.fromAsset('shaders/burn.frag')
        .then<ui.FragmentProgram?>((p) => _program = p)
        .catchError((Object _) {
      // A device without shader support, or an asset that did not ship. The
      // widget falls back to a fade and the message still disappears.
      _failed = true;
      return null;
    });
  }
}

/// Plays the burn over [child], then calls [onGone].
class Burning extends StatefulWidget {
  const Burning({
    super.key,
    required this.child,
    required this.onGone,
    this.duration = _burnDuration,
  });

  final Widget child;
  final VoidCallback onGone;
  final Duration duration;

  @override
  State<Burning> createState() => _BurningState();
}

class _BurningState extends State<Burning> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  /// Moves per message, so no two burn the same way.
  final double _seed = Random().nextDouble() * 100;

  /// How far the embers are allowed to travel outside the bubble.
  ///
  /// Above rather than around, because they rise. Wide enough sideways for the
  /// drift, and the layer ignores pointers so none of it is in the way.
  static const double _above = 130;
  static const double _beside = 40;

  ui.FragmentProgram? _program;

  @override
  void initState() {
    super.initState();

    BurnShader.load().then((program) {
      if (!mounted) return;
      setState(() => _program = program);
    });

    _controller.forward().whenComplete(widget.onGone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final program = _program;
        final progress = _controller.value;

        // No shader: fade and shrink, which says "gone" without pretending.
        if (program == null) {
          return Opacity(
            opacity: 1 - progress,
            child: Transform.scale(scale: 1 - progress * 0.12, child: widget.child),
          );
        }

        return Stack(
          // The embers leave the bubble, so nothing here may clip.
          clipBehavior: Clip.none,
          children: [
            ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) =>
                  _shader(program, rect, progress, mode: 0),
              child: widget.child,
            ),

            // The flame, over the tear it is cutting.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _BurnPainter(
                    program: program,
                    progress: progress,
                    seed: _seed,
                    mode: 1,
                  ),
                ),
              ),
            ),

            // The embers, on a canvas larger than the bubble so they can
            // leave it. Negative insets in a Stack that does not clip: the
            // conversation's layout is unchanged, and the painter simply gets
            // more room than the bubble occupies.
            Positioned(
              left: -_beside,
              right: -_beside,
              top: -_above,
              bottom: 0,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _BurnPainter(
                    program: program,
                    progress: progress,
                    seed: _seed,
                    mode: 2,
                    // The bubble occupies everything except the margin that was
                    // just added, which is how the shader knows where the
                    // sparks come from.
                    inset: const EdgeInsets.only(left: _beside, top: _above, right: _beside),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  ui.FragmentShader _shader(
    ui.FragmentProgram program,
    Rect rect,
    double progress, {
    required double mode,
  }) {
    // Uniform slots are positional and in declaration order: uSize is 0 and 1,
    // then progress, seed and mode. Getting the order wrong shows as a shader
    // that draws nothing, with no error anywhere, so it is worth stating.
    return program.fragmentShader()
      ..setFloat(0, rect.width)
      ..setFloat(1, rect.height)
      ..setFloat(2, progress)
      ..setFloat(3, _seed)
      ..setFloat(4, mode)
      // The mask pass does not read these, but every uniform has to be set or
      // the shader draws nothing at all, with no error anywhere.
      ..setFloat(5, 0)
      ..setFloat(6, 0)
      ..setFloat(7, rect.width)
      ..setFloat(8, rect.height);
  }
}

class _BurnPainter extends CustomPainter {
  _BurnPainter({
    required this.program,
    required this.progress,
    required this.seed,
    required this.mode,
    this.inset = EdgeInsets.zero,
  });

  final ui.FragmentProgram program;
  final double progress;
  final double seed;

  /// 1 is the flame on the tear, 2 is the embers.
  final double mode;

  /// How much larger this canvas is than the bubble inside it. Only the ember
  /// pass reads it.
  final EdgeInsets inset;

  @override
  void paint(Canvas canvas, Size size) {
    final within = Rect.fromLTWH(
      inset.left,
      inset.top,
      size.width - inset.horizontal,
      size.height - inset.vertical,
    );

    final shader = program.fragmentShader()
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, progress)
      ..setFloat(3, seed)
      ..setFloat(4, mode)
      ..setFloat(5, within.left)
      ..setFloat(6, within.top)
      ..setFloat(7, within.width)
      ..setFloat(8, within.height);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_BurnPainter old) =>
      old.progress != progress || old.seed != seed || old.mode != mode;

  @override
  bool hitTest(Offset position) => false;
}
