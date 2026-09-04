/// Choosing a PIN, twice, so a typing mistake does not lock somebody out.
///
/// # Why it is confirmed and the unlock screen is not
///
/// Getting the unlock screen wrong costs an attempt. Getting this one wrong
/// costs the application: a PIN that was set to something other than what its
/// owner believes is a PIN nobody can enter, and there is nothing here that can
/// recover it, because there is no account and no reset.
library;

import 'package:flutter/material.dart';

import '../../rotelyx/lock.dart';
import '../theme.dart';
import '../widgets.dart';

class SetPinSheet extends StatefulWidget {
  const SetPinSheet({super.key});

  /// Returns the chosen PIN, or null if they backed out.
  static Future<String?> ask(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: t.surface,
      isScrollControlled: true,
      // Grows to the height of the screen, so without this it grows past the
      // status bar and the first line is drawn behind the clock.
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => RotelyxThemeScope(theme: t, child: const SetPinSheet()),
    );
  }

  @override
  State<SetPinSheet> createState() => _SetPinSheetState();
}

class _SetPinSheetState extends State<SetPinSheet> {
  final _first = TextEditingController();
  final _again = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _first.dispose();
    _again.dispose();
    super.dispose();
  }

  void _save() {
    final pin = _first.text.trim();

    if (pin.length < minPinLength) {
      setState(() => _problem = 'At least $minPinLength digits.');
      return;
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      setState(() => _problem = 'Digits only, so the keypad can enter it.');
      return;
    }
    if (pin != _again.text.trim()) {
      setState(() => _problem = 'Those two do not match.');
      return;
    }

    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    InputDecoration box(String hint) => InputDecoration(
          hintText: hint,
          hintStyle: Type.body.copyWith(color: t.faint),
          filled: true,
          fillColor: t.raised,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Metrics.radius),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Metrics.gap,
          right: Metrics.gap,
          top: Metrics.gap,
          bottom: MediaQuery.of(context).viewInsets.bottom + Metrics.gap,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Choose a PIN', style: Type.title.copyWith(color: t.text)),
            const SizedBox(height: 6),
            Text(
              'Six digits is meaningfully better than four, and takes the same '
              'moment to type.',
              style: Type.small.copyWith(color: t.faint),
            ),
            const SizedBox(height: Metrics.gap),
            TextField(
              controller: _first,
              obscureText: true,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: Type.body.copyWith(color: t.text, letterSpacing: 4),
              decoration: box('PIN'),
              onChanged: (_) => setState(() => _problem = null),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _again,
              obscureText: true,
              keyboardType: TextInputType.number,
              style: Type.body.copyWith(color: t.text, letterSpacing: 4),
              decoration: box('The same again'),
              onChanged: (_) => setState(() => _problem = null),
              onSubmitted: (_) => _save(),
            ),
            if (_problem != null) ...[
              const SizedBox(height: 8),
              Text(_problem!,
                  style: Type.small.copyWith(color: const Color(0xFFE0574A))),
            ],
            const SizedBox(height: Metrics.gap),
            const RxNote(
              'Nothing here can recover a PIN you have forgotten. There is no '
              'account behind this application and nobody to ask. That is the '
              'same reason your messages are private and it cuts both ways.',
            ),
            const SizedBox(height: Metrics.gap),
            RxButton('Set it', onTap: _save),
          ],
        ),
      ),
    );
  }
}
