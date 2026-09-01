/// A call in progress, or one that is ringing.
///
/// # What this screen is responsible for
///
/// Showing who, showing how long, and offering the two or three things a person
/// does during a call. Not the audio, not the codec, not the connection: those
/// are `call_loop.dart`, and this screen holds one and asks it how it is doing.
///
/// # Why the screen keeps the wake lock rather than the loop
///
/// Because the loop does not know whether anybody is looking. A call continues
/// with the screen off and should; what should not happen is the screen staying
/// lit in a pocket for twenty minutes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import '../../rotelyx/dtmf.dart';

import '../../rotelyx/call_loop.dart';
import '../../rotelyx/call_state.dart';
import '../theme.dart';
import '../widgets.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.who,
    required this.state,
    required this.loop,
    required this.onAnswer,
    required this.onEnd,
    this.because,
  });

  /// Their name as this device knows it.
  final String who;

  final CallState state;

  /// Why the last call failed, when there is more to say than "it ended".
  ///
  /// Passed in rather than read from the service, so this screen stays a screen.
  final String? because;

  /// Null until the call is up. Ringing has no audio.
  final CallLoop? loop;

  final VoidCallback onAnswer;
  final void Function(CallEnded why) onEnd;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;
  Timer? _paint;
  CallHealth? _health;
  bool _speaker = false;
  bool _muted = false;
  bool _keypad = false;

  /// A ring with nothing in it yet, so the shape is there before the first
  /// frame arrives and the screen does not grow when a call connects.
  static final _quiet = Float64List(CallLoop.historyLength);

  @override
  void initState() {
    super.initState();

    // One timer for the duration and the health together. Two would drift
    // against each other for no benefit.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      final loop = widget.loop;
      final health = loop == null ? null : await loop.health();
      if (mounted) setState(() => _health = health);
    });

    // And a fast one for the ring alone.
    //
    // Separate because they answer different questions. The health figures
    // cost a round trip to the engine and change slowly; the ring is reading
    // two arrays the call loop is already filling and has to move at something
    // a person reads as motion. Thirty a second, which is under the frame rate
    // and above the point where a voice stops looking continuous.
    //
    // Only while there is a loop to read. A ringing screen has no audio yet,
    // and repainting nothing thirty times a second on a phone that may ring
    // for a minute is battery spent on a still image.
    _paint = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted || widget.loop == null) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _paint?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final phase = widget.state.phase;

    return Container(
      color: t.backdrop,
      // The full width, stated rather than inherited from whatever is inside.
      //
      // A Column is as wide as its widest child. While a call is up that child
      // is the row of controls, which fills the screen; when it ends the row
      // is replaced by a spacer with a height and no width, the column
      // collapses to the width of the name, and everything on the screen
      // jumps sideways at the moment somebody hangs up.
      width: double.infinity,
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),

            // The avatar inside the ring rather than beside it: the circle is
            // who the call is with, and the two voices are drawn around it.
            _VoiceRing(
              size: 200,
              speaking: widget.loop?.speaking ?? _quiet,
              hearing: widget.loop?.hearing ?? _quiet,
              child: RxAvatar(widget.who, size: 96),
            ),
            const SizedBox(height: Metrics.gap),
            Text(widget.who,
                style: Type.display.copyWith(color: t.text, fontSize: 26)),
            const SizedBox(height: 6),
            _Status(state: widget.state, health: _health, because: widget.because),
            const Spacer(flex: 3),

            // Only while a call is up. There is nothing to send a tone into
            // before that, and a keypad on a ringing screen invites a press
            // that would be silently discarded.
            if (_keypad && phase == CallPhase.talking) ...[
              _Keypad(onKey: (key) => widget.loop?.sendDigit(key)),
              const SizedBox(height: Metrics.gap),
            ],
            _Controls(
              phase: phase,
              speaker: _speaker,
              muted: _muted,
              onSpeaker: () {
                setState(() => _speaker = !_speaker);
                widget.loop?.useSpeakerphone(_speaker);
              },
              onMute: () {
                setState(() => _muted = !_muted);
                widget.loop?.mute(_muted);
              },
              keypad: _keypad,
              onKeypad: () => setState(() => _keypad = !_keypad),
              onAnswer: () {
                HapticFeedback.lightImpact();
                widget.onAnswer();
              },
              onEnd: () {
                HapticFeedback.mediumImpact();
                widget.onEnd(phase == CallPhase.ringingIn
                    ? CallEnded.declined
                    : CallEnded.hungUp);
              },
            ),
            const SizedBox(height: Metrics.gap),
          ],
        ),
      ),
    );
  }
}

/// What the call is doing, in one line.
class _Status extends StatelessWidget {
  const _Status({required this.state, required this.health, this.because});

  final CallState state;
  final CallHealth? health;

  /// Why a lost call was lost. See [_ending].
  final String? because;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    final (text, colour) = switch (state.phase) {
      CallPhase.ringingOut => ('Ringing', t.muted),
      CallPhase.ringingIn => ('Incoming call', Tone.accent),
      CallPhase.talking => (_duration(state.talkingFor), t.muted),
      CallPhase.over => (_ending(state.ended, because), t.faint),
      CallPhase.idle => ('', t.faint),
    };

    return Column(
      children: [
        // Centred explicitly, and held to a readable width. While a call is up
        // this line is "0:05" and any alignment looks the same; when it ends it
        // becomes a sentence, and a Text left to itself sets from the start
        // edge, so the ending appeared to jump to the left.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Type.body.copyWith(color: colour),
          ),
        ),
        // Only when it is worth saying. A quality line that is always there is
        // one nobody reads; one that appears when a call starts breaking up is
        // the difference between "they hung up" and "this connection is bad".
        if (health != null && health!.isStruggling) ...[
          const SizedBox(height: 8),
          const RxChip('Poor connection', icon: Icons.signal_cellular_alt_1_bar),
        ],
        const SizedBox(height: 10),
        Text('Relayed, end to end encrypted',
            textAlign: TextAlign.center,
            style: Type.small.copyWith(color: t.faint)),
      ],
    );
  }

  static String _duration(Duration? d) {
    if (d == null) return 'Connected';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// What to show when a call is over.
  ///
  /// # Why a lost call says more than "lost"
  ///
  /// Three different faults end a call the same way: the media connection never
  /// arrived, this build has no codec, or something threw. `Calls._open` works
  /// out which and used to return it to a caller that discarded the value, so
  /// all three drew **Connection lost** and there was no way to tell a relay
  /// that cannot be reached from a build with no codec in it.
  ///
  /// Only for a lost call. A declined or unanswered one has nothing further to
  /// explain and a reason there would be noise.
  static String _ending(CallEnded? why, String? because) => switch (why) {
        CallEnded.declined => 'Declined',
        CallEnded.unanswered => 'No answer',
        CallEnded.lost when because != null && because.isNotEmpty =>
          'Connection lost: $because',
        CallEnded.lost => 'Connection lost',
        CallEnded.hungUp || null => 'Call ended',
      };
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.phase,
    required this.speaker,
    required this.muted,
    required this.keypad,
    required this.onSpeaker,
    required this.onMute,
    required this.onKeypad,
    required this.onAnswer,
    required this.onEnd,
  });

  final CallPhase phase;
  final bool speaker;
  final bool muted;
  final bool keypad;
  final VoidCallback onSpeaker;
  final VoidCallback onMute;
  final VoidCallback onKeypad;
  final VoidCallback onAnswer;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE0574A);
    const green = Color(0xFF3BA55D);

    // Ringing in is the one case with two buttons, and they are deliberately
    // far apart: answering and declining an unexpected call happen with a thumb
    // that is not looking, and adjacent buttons make that a coin toss.
    if (phase == CallPhase.ringingIn) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Round(icon: Icons.call_end, colour: red, onTap: onEnd, label: 'Decline'),
          _Round(icon: Icons.call, colour: green, onTap: onAnswer, label: 'Answer'),
        ],
      );
    }

    // Keeps the row's height so nothing above it moves, and its width so
    // nothing beside it does either. See the note on the container.
    if (phase == CallPhase.over) {
      return const SizedBox(height: 88, width: double.infinity);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _Round(
          icon: muted ? Icons.mic_off : Icons.mic,
          colour: muted ? Tone.accent : null,
          onTap: onMute,
          label: muted ? 'Unmute' : 'Mute',
        ),
        _Round(
          icon: Icons.dialpad,
          colour: keypad ? Tone.accent : null,
          onTap: onKeypad,
          label: 'Keypad',
        ),
        _Round(icon: Icons.call_end, colour: red, onTap: onEnd, label: 'End'),
        _Round(
          icon: speaker ? Icons.volume_up : Icons.hearing,
          colour: speaker ? Tone.accent : null,
          onTap: onSpeaker,
          label: speaker ? 'Speaker' : 'Earpiece',
        ),
      ],
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({
    required this.icon,
    required this.onTap,
    required this.label,
    this.colour,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String label;
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final background = colour ?? t.raised;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon,
                  size: 26,
                  color: colour == null ? t.text : Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: Type.small.copyWith(color: t.faint)),
      ],
    );
  }
}


/// The touch tone keypad, shown during a call.
///
/// Only while a call is up, because the tones are mixed into the microphone
/// and there is nothing to mix them into before that. Laid out as a telephone
/// is laid out, in `dtmf.dart`, so muscle memory works.
class _Keypad extends StatelessWidget {
  const _Keypad({required this.onKey});

  final void Function(String) onKey;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in keypad)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final key in row)
                  Semantics(
                    button: true,
                    label: 'Send $key',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onKey(key);
                      },
                      child: Container(
                        width: 60,
                        height: 60,
                        alignment: Alignment.center,
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: t.surface,
                        ),
                        child: Text(
                          key,
                          style: Type.display.copyWith(
                            color: t.text,
                            fontSize: 24,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The two voices in a call, drawn as one ring around the avatar.
///
/// # What it shows, and why this shape
///
/// A call has exactly two things worth watching and they are not the same
/// thing: what this person is sending, and what is arriving. Two rings around
/// one circle says that without a label, because the circle between them is
/// who they are talking to.
///
/// The outer ring is the other side and the inner one is this device. That way
/// round because the outer has more room to move, and the far end is the one
/// somebody is actually trying to hear: a call where the outer ring is flat is
/// a call where the other person has stopped, which is the thing worth
/// noticing at a glance.
///
/// Time runs clockwise from the top, oldest to newest, so the newest sample is
/// always arriving back at twelve o'clock and a word looks like a wave that
/// travels round.
class _VoiceRing extends StatelessWidget {
  const _VoiceRing({
    required this.speaking,
    required this.hearing,
    required this.size,
    required this.child,
  });

  final Float64List speaking;
  final Float64List hearing;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          speaking: speaking,
          hearing: hearing,
          mine: Tone.accent,
          theirs: t.text,
        ),
        child: Center(child: child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.speaking,
    required this.hearing,
    required this.mine,
    required this.theirs,
  });

  final Float64List speaking;
  final Float64List hearing;
  final Color mine;
  final Color theirs;

  /// Where each ring sits, as a fraction of the half width, and how far a full
  /// scale sample pushes it. The inner ring is given less room than the outer
  /// so that two loud voices at once stay two rings rather than one band.
  static const _innerRadius = 0.60;
  static const _innerReach = 0.10;
  static const _outerRadius = 0.78;
  static const _outerReach = 0.20;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final half = size.width / 2;

    _ring(canvas, centre, half, hearing, _outerRadius, _outerReach, theirs);
    _ring(canvas, centre, half, speaking, _innerRadius, _innerReach, mine);
  }

  void _ring(
    Canvas canvas,
    Offset centre,
    double half,
    Float64List history,
    double radius,
    double reach,
    Color colour,
  ) {
    if (history.isEmpty) return;

    final base = half * radius;
    final path = Path();

    // Closed and filled rather than stroked, because a stroke of varying width
    // has to be built as a polygon anyway and a filled ring reads as a single
    // body of sound instead of a line that happens to wobble.
    for (var i = 0; i < history.length; i++) {
      final turn = i / history.length * 2 * math.pi - math.pi / 2;
      final r = base + half * reach * history[i];
      final point = Offset(
        centre.dx + math.cos(turn) * r,
        centre.dy + math.sin(turn) * r,
      );
      i == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
    }
    path.close();

    // The quiet ring is still there, at rest, so a silent call looks like a
    // call rather than like a failure.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = colour.withOpacity(0.75),
    );

    // A faint fill under it, which is what stops two overlapping rings reading
    // as a tangle of lines.
    canvas.drawPath(path, Paint()..color = colour.withOpacity(0.07));
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}
