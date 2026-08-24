/// Shared pieces. Small, unstyled-by-default, and composed rather than
/// configured, a widget with fifteen optional parameters is a stylesheet
/// wearing a costume.
library;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The app's button. One shape, three weights.
enum Weight { primary, secondary, quiet }

class RxButton extends StatelessWidget {
  const RxButton(
    this.label, {
    super.key,
    required this.onTap,
    this.weight = Weight.primary,
    this.icon,
    this.busy = false,
    this.wide = false,
  });

  final String label;
  final VoidCallback? onTap;
  final Weight weight;
  final IconData? icon;
  final bool busy;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final enabled = onTap != null && !busy;

    final (bg, fg, border) = switch (weight) {
      Weight.primary => (Tone.accent, Colors.white, null),
      Weight.secondary => (Colors.transparent, Tone.accent, Tone.accent),
      Weight.quiet => (Colors.transparent, t.muted, null),
    };

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(Metrics.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(Metrics.radius),
          onTap: enabled ? onTap : null,
          child: Container(
            height: 46,
            width: wide ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: Metrics.pad),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Metrics.radius),
              border: border == null ? null : Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                else if (icon != null)
                  Icon(icon, size: 17, color: fg),
                if (busy || icon != null) const SizedBox(width: Metrics.gap),
                // Flexible, and one line with an ellipsis.
                //
                // Without it the label sets its own width and the row overflows
                // rather than the text shrinking, which on a narrow phone means
                // a button with a yellow and black hazard stripe down its edge.
                // Found by the widget test that was written when the desktop
                // targets were scaffolded: the application had never been laid
                // out at anything but a phone, and it overflowed at every width
                // that test tried.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Type.label.copyWith(color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RxField extends StatelessWidget {
  const RxField({
    super.key,
    required this.controller,
    required this.hint,
    this.label,
    this.help,
    this.obscure = false,
    this.lines = 1,
    this.onSubmit,
    this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final String? label;
  final String? help;
  final bool obscure;
  final int lines;
  final ValueChanged<String>? onSubmit;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(label!, style: Type.label.copyWith(color: t.muted)),
          const SizedBox(height: 6),
        ],
        TextField(
          controller: controller,
          obscureText: obscure,
          maxLines: obscure ? 1 : lines,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: onSubmit,
          style: Type.body.copyWith(color: t.text),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: Type.body.copyWith(color: t.faint),
            filled: true,
            fillColor: t.raised,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: Metrics.pad, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Metrics.radius),
              borderSide: BorderSide(color: t.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Metrics.radius),
              borderSide: BorderSide(color: t.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Metrics.radius),
              borderSide: const BorderSide(color: Tone.accent, width: 1.5),
            ),
          ),
        ),
        if (help != null) ...[
          const SizedBox(height: 6),
          Text(help!, style: Type.small.copyWith(color: t.faint)),
        ],
      ],
    );
  }
}

/// A short, quiet statement of fact. Used for route, epoch and protocol -
/// things worth showing continuously and never worth shouting.
class RxChip extends StatelessWidget {
  const RxChip(this.text, {super.key, this.tone, this.icon});

  final String text;
  final Color? tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final c = tone ?? t.muted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.withOpacity(0.11),
        borderRadius: BorderRadius.circular(Metrics.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 5),
          ],
          Text(text,
              style: Type.small.copyWith(
                  color: c, fontWeight: FontWeight.w600, height: 1)),
        ],
      ),
    );
  }
}

/// A card that explains something the user should read once.
class RxNote extends StatelessWidget {
  const RxNote(this.text, {super.key, this.tone, this.title});

  final String text;
  final String? title;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final c = tone ?? t.faint;

    return Container(
      padding: const EdgeInsets.all(Metrics.pad),
      decoration: BoxDecoration(
        color: c.withOpacity(0.06),
        borderRadius: BorderRadius.circular(Metrics.radius),
        border: Border.all(color: c.withOpacity(0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(title!, style: Type.label.copyWith(color: c)),
            const SizedBox(height: 5),
          ],
          Text(text, style: Type.small.copyWith(color: t.muted)),
        ],
      ),
    );
  }
}

/// An avatar built from the label, since there are no profile pictures to
/// fetch and no server to fetch them from.
class RxAvatar extends StatelessWidget {
  const RxAvatar(this.name, {super.key, this.size = 40});

  final String name;
  final double size;

  static const _palette = [
    Color(0xFF6A31EE), Color(0xFF0EA5E9), Color(0xFF10B981),
    Color(0xFFF59E0B), Color(0xFFEC4899), Color(0xFF8B5CF6),
  ];

  @override
  Widget build(BuildContext context) {
    final seed = name.isEmpty
        ? 0
        : name.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length;
    final colour = _palette[seed];
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withOpacity(0.18),
        shape: BoxShape.circle,
        border: Border.all(color: colour.withOpacity(0.4)),
      ),
      child: Text(initial,
          style: Type.label.copyWith(color: colour, fontSize: size * 0.4)),
    );
  }
}

/// Makes the palette reachable without threading it through every constructor.
class RotelyxThemeScope extends InheritedWidget {
  const RotelyxThemeScope({
    super.key,
    required this.theme,
    required super.child,
  });

  final RotelyxTheme theme;

  static RotelyxTheme of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<RotelyxThemeScope>()
          ?.theme ??
      RotelyxTheme.dark;

  @override
  bool updateShouldNotify(RotelyxThemeScope oldWidget) =>
      oldWidget.theme != theme;
}

/// A decision offered as two or three cards rather than as a form.
///
/// # Why this exists
///
/// A choice with real consequences was being made through a text field and a
/// quiet link underneath it, which puts the weight on the wrong thing: the
/// field looked like the task and the decision looked like a way to skip it.
/// A card states the outcome first and the mechanism second, which is the order
/// a person actually thinks in.
class RxChoice extends StatefulWidget {
  const RxChoice({
    super.key,
    required this.title,
    required this.body,
    required this.icon,
    required this.onTap,
    this.tone,
  });

  final String title;
  final String body;
  final IconData icon;
  final VoidCallback onTap;

  /// Defaults to the accent. Set it where a choice deserves to read as the
  /// quieter of the two.
  final Color? tone;

  @override
  State<RxChoice> createState() => _RxChoiceState();
}

class _RxChoiceState extends State<RxChoice> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final c = widget.tone ?? Tone.accent;

    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.985 : 1,
        duration: Motion.press,
        curve: Motion.pressCurve,
        child: AnimatedContainer(
          duration: Motion.press,
          curve: Motion.pressCurve,
          padding: const EdgeInsets.all(Metrics.pad),
          decoration: BoxDecoration(
            color: _down ? c.withOpacity(0.08) : t.raised,
            borderRadius: BorderRadius.circular(Metrics.radius),
            border: Border.all(
                color: _down ? c.withOpacity(0.5) : t.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: c.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(widget.icon, size: 19, color: c),
              ),
              const SizedBox(width: Metrics.pad),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: Type.title.copyWith(fontSize: 16)),
                    const SizedBox(height: 3),
                    Text(widget.body,
                        style: Type.small.copyWith(color: t.muted)),
                  ],
                ),
              ),
              const SizedBox(width: Metrics.gap),
              Icon(Icons.chevron_right, size: 20, color: t.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fades and lifts its child into place, once.
///
/// # Why once matters more than the animation
///
/// A list that staggers every time it rebuilds is not alive, it is broken: a
/// message arriving would replay the whole screen, and on a conversation list
/// that repaints on every receipt the effect is a permanent shimmer. So the
/// controller runs on the first build of this element and never again, and the
/// element is what Flutter reuses as the list scrolls.
///
/// [index] only delays the start. Past [maxStagger] items the delay stops
/// growing, because a list of forty should not take two seconds to finish
/// arriving.
class RxEnter extends StatefulWidget {
  const RxEnter({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  /// Beyond this the delay is capped. Eight rows is about one screen.
  static const maxStagger = 8;

  @override
  State<RxEnter> createState() => _RxEnterState();
}

class _RxEnterState extends State<RxEnter> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: Motion.enter,
  );

  @override
  void initState() {
    super.initState();

    final steps = widget.index.clamp(0, RxEnter.maxStagger);
    final delay = Motion.stagger * steps;

    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      Future<void>.delayed(delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion is a system setting somebody turned on for a reason, and
    // an entrance is exactly the kind of thing they turned it off for.
    if (MediaQuery.of(context).disableAnimations) return widget.child;

    final curved =
        CurvedAnimation(parent: _controller, curve: Motion.enterCurve);

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}
