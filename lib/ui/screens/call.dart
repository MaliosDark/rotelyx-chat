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
import 'dart:ui' as ui;

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

            RxAvatar(widget.who, size: 96),
            const SizedBox(height: Metrics.gap),
            Text(widget.who,
                style: Type.display.copyWith(color: t.text, fontSize: 26)),
            const SizedBox(height: 6),
            _Status(state: widget.state, health: _health, because: widget.because),

            const SizedBox(height: 26),
            // The two voices, under the person they belong to.
            _VoiceWave(
              speaking: widget.loop?.speaking ?? _quiet,
              hearing: widget.loop?.hearing ?? _quiet,
            ),
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

/// The two voices in a call, drawn as one wave.
///
/// # What it shows, and why this shape
///
/// A call has exactly two things worth watching and they are not the same
/// thing: what is arriving, and what this device is sending. They are drawn as
/// one mirrored wave, the far end above the line and this device below it, so
/// the two are told apart by side rather than by a label and the space between
/// them is the conversation.
///
/// This replaced two rings around the avatar. The rings said the same thing
/// and said it in polar coordinates, where a loud moment is a bulge whose size
/// depends on which way round the circle it happened to fall, and where the
/// two voices were told apart by radius, which is the hardest length for an
/// eye to compare. A bar has one dimension and it is the one being measured.
///
/// # The far end is on top
///
/// The same reason it was the outer ring: the far end is what somebody is
/// actually trying to hear, and a flat top is a call where the other person
/// has stopped, which is the thing worth noticing without looking for it.
///
/// # Time runs to the right
///
/// Newest at the right edge, the way every waveform anybody has seen reads, so
/// a word is a shape that travels off the end rather than one that arrives
/// back where it started.
class _VoiceWave extends StatelessWidget {
  const _VoiceWave({required this.speaking, required this.hearing});

  final Float64List speaking;
  final Float64List hearing;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: SizedBox(
        height: 92,
        width: double.infinity,
        child: CustomPaint(
          painter: _WavePainter(
            speaking: speaking,
            hearing: hearing,
            mine: Tone.accent,
            theirs: t.text,
            rest: t.line,
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.speaking,
    required this.hearing,
    required this.mine,
    required this.theirs,
    required this.rest,
  });

  final Float64List speaking;
  final Float64List hearing;
  final Color mine;
  final Color theirs;
  final Color rest;

  /// How wide a bar is and how much air sits between two of them.
  ///
  /// Three and two rather than one and one: a bar thinner than the gap reads as
  /// a comb, and one wider than it reads as a block with notches. Rounded caps
  /// need something to round.
  static const _bar = 3.0;
  static const _gap = 2.0;

  /// The shortest a bar is ever drawn, in logical pixels.
  ///
  /// A silent call still shows a line of stubs rather than nothing at all. The
  /// screen that goes blank when nobody speaks is the screen somebody reads as
  /// broken, and a call is mostly silence.
  static const _floor = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final middle = size.height / 2;
    final reach = middle - 6;
    final step = _bar + _gap;
    final columns = (size.width / step).floor();
    if (columns <= 0) return;

    // The line the two voices are mirrored about. Drawn first and faintly, so
    // it is there when both sides are quiet and never competes when they are
    // not.
    canvas.drawLine(
      Offset(0, middle),
      Offset(size.width, middle),
      Paint()
        ..color = rest.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );

    for (var column = 0; column < columns; column++) {
      final x = column * step;

      // Older to the left, newest at the right edge.
      final at = columns == 1 ? 1.0 : column / (columns - 1);

      // Fades into the left edge rather than stopping at it, so the oldest
      // sample leaves rather than being cut off.
      final fade = (0.25 + at * 0.75).clamp(0.0, 1.0);

      _column(canvas, x, middle, -1, reach, _sample(hearing, at), theirs, fade);
      _column(canvas, x, middle, 1, reach, _sample(speaking, at), mine, fade);
    }
  }

  /// The level at `at`, where 0 is the oldest sample held and 1 the newest.
  ///
  /// Read rather than indexed, because the number of bars follows the width of
  /// the screen and the number of samples follows the audio, and neither is
  /// the other's business.
  double _sample(Float64List history, double at) {
    if (history.isEmpty) return 0;
    final i = (at * (history.length - 1)).round().clamp(0, history.length - 1);
    return history[i].abs().clamp(0.0, 1.0);
  }

  void _column(
    Canvas canvas,
    double x,
    double middle,
    double direction,
    double reach,
    double level,
    Color colour,
    double fade,
  ) {
    // The square root rather than the level itself. Loudness is not linear in
    // amplitude, and a bar drawn linearly spends most of a normal voice in the
    // bottom fifth of the space it was given: the wave looks flat while
    // somebody is plainly talking.
    final height = _floor + (reach - _floor) * math.sqrt(level);

    final top = direction < 0 ? middle - height : middle;
    final rect = Rect.fromLTWH(x, top, _bar, height);

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(_bar / 2)),
      Paint()
        // Brighter at the tip than at the line, which is what stops a wall of
        // bars reading as a solid block.
        ..shader = ui.Gradient.linear(
          Offset(x, middle),
          Offset(x, direction < 0 ? middle - reach : middle + reach),
          [colour.withValues(alpha: 0.35 * fade), colour.withValues(alpha: fade)],
        ),
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}
