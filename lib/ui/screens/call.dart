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
import 'package:flutter/services.dart';

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
  });

  /// Their name as this device knows it.
  final String who;

  final CallState state;

  /// Null until the call is up. Ringing has no audio.
  final CallLoop? loop;

  final VoidCallback onAnswer;
  final void Function(CallEnded why) onEnd;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;
  CallHealth? _health;
  bool _speaker = false;
  bool _muted = false;

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
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final phase = widget.state.phase;

    return Container(
      color: t.backdrop,
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            RxAvatar(widget.who, size: 96),
            const SizedBox(height: Metrics.gap),
            Text(widget.who,
                style: Type.display.copyWith(color: t.text, fontSize: 26)),
            const SizedBox(height: 6),
            _Status(state: widget.state, health: _health),
            const Spacer(flex: 3),
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
  const _Status({required this.state, required this.health});

  final CallState state;
  final CallHealth? health;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    final (text, colour) = switch (state.phase) {
      CallPhase.ringingOut => ('Ringing', t.muted),
      CallPhase.ringingIn => ('Incoming call', Tone.accent),
      CallPhase.talking => (_duration(state.talkingFor), t.muted),
      CallPhase.over => (_ending(state.ended), t.faint),
      CallPhase.idle => ('', t.faint),
    };

    return Column(
      children: [
        Text(text, style: Type.body.copyWith(color: colour)),
        // Only when it is worth saying. A quality line that is always there is
        // one nobody reads; one that appears when a call starts breaking up is
        // the difference between "they hung up" and "this connection is bad".
        if (health != null && health!.isStruggling) ...[
          const SizedBox(height: 8),
          const RxChip('Poor connection', icon: Icons.signal_cellular_alt_1_bar),
        ],
        const SizedBox(height: 10),
        Text('Relayed, end to end encrypted',
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

  static String _ending(CallEnded? why) => switch (why) {
        CallEnded.declined => 'Declined',
        CallEnded.unanswered => 'No answer',
        CallEnded.lost => 'Connection lost',
        CallEnded.hungUp || null => 'Call ended',
      };
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.phase,
    required this.speaker,
    required this.muted,
    required this.onSpeaker,
    required this.onMute,
    required this.onAnswer,
    required this.onEnd,
  });

  final CallPhase phase;
  final bool speaker;
  final bool muted;
  final VoidCallback onSpeaker;
  final VoidCallback onMute;
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

    if (phase == CallPhase.over) return const SizedBox(height: 88);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _Round(
          icon: muted ? Icons.mic_off : Icons.mic,
          colour: muted ? Tone.accent : null,
          onTap: onMute,
          label: muted ? 'Unmute' : 'Mute',
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
