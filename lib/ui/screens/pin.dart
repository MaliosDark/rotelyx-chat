/// The PIN screen, and the keypad it is entered on.
///
/// # Why a keypad and not the system keyboard
///
/// A numeric keyboard is drawn in a different place on every device and it
/// shifts as somebody types. A fixed keypad is the same three columns every
/// time, which is what lets a person enter a PIN without looking at the screen,
/// and not looking at the screen is most of what makes it private in a room
/// with other people in it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/biometrics.dart';
import '../../rotelyx/lock.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../theme.dart';
import '../widgets.dart';
import '../brand.dart';

/// Ask for the PIN, and do not come back until it is right.
class PinScreen extends StatefulWidget {
  const PinScreen({super.key, required this.onOpened});

  final VoidCallback onOpened;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _entered = '';
  String? _problem;
  Timer? _tick;

  bool _offerBiometric = false;

  @override
  void initState() {
    super.initState();

    // Offered as soon as the screen appears, because somebody who switched it
    // on wants their thumb to be the whole interaction rather than a second
    // step after looking at a keypad.
    if (store.useBiometric) {
      biometricsAvailable().then((can) {
        if (!mounted || !can) return;
        setState(() => _offerBiometric = true);
        _tryBiometric();
      });
    }
    // While locked out, the countdown has to move on its own. Without this it
    // says the same number until somebody presses a key, which reads as frozen.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && lock.lockedOutFor > 0) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    if (lock.lockedOutFor > 0) return;
    if (await askBiometric() && mounted) widget.onOpened();
  }

  void _press(String digit) {
    if (lock.lockedOutFor > 0) return;
    if (_entered.length >= 12) return;

    setState(() {
      _entered += digit;
      _problem = null;
    });

    if (_entered.length >= minPinLength) _tryIt();
  }

  void _back() {
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _problem = null;
    });
  }

  /// Checked as soon as it is long enough, and again on every digit after.
  ///
  /// There is no Done button. A PIN of unknown length has to be checked as it
  /// grows, and a button would only tell an onlooker how long yours is.
  void _tryIt() {
    final answer = lock.check(_entered);

    if (answer == true) {
      HapticFeedback.lightImpact();
      widget.onOpened();
      return;
    }

    if (answer == null) {
      setState(() => _entered = '');
      return;
    }

    // Only complain once the entry is at least as long as a PIN can be, or
    // every fourth digit of a six digit PIN reports a failure on the way past.
    if (_entered.length < 6) return;

    HapticFeedback.mediumImpact();
    setState(() {
      _entered = '';
      _problem = lock.attemptsLeft <= 3
          ? '${lock.attemptsLeft} attempts left'
          : 'That is not the PIN';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final waiting = lock.lockedOutFor;

    return Container(
      color: t.backdrop,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const RxWordmark(height: 68),
                const SizedBox(height: Metrics.gap),
                Text(
                  waiting > 0 ? 'Too many attempts' : 'Enter your PIN',
                  style: Type.title.copyWith(color: t.text),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 34,
                  child: Text(
                    waiting > 0
                        ? 'Try again in ${_clock(waiting)}'
                        : _problem ?? 'This unlocks the app on this device',
                    textAlign: TextAlign.center,
                    style: Type.small.copyWith(
                        color: _problem == null ? t.faint : const Color(0xFFE0574A)),
                  ),
                ),
                const SizedBox(height: Metrics.pad),
                _Dots(count: _entered.length, dimmed: waiting > 0),
                const SizedBox(height: Metrics.gap),
                Opacity(
                  opacity: waiting > 0 ? 0.35 : 1,
                  child: _Keypad(onDigit: _press, onBack: _back),
                ),
                if (_offerBiometric && waiting == 0) ...[
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: _tryBiometric,
                    icon: Icon(Icons.fingerprint, size: 20, color: t.muted),
                    label: Text('Use your fingerprint',
                        style: Type.body.copyWith(color: t.muted)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _clock(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return m > 0 ? '$m min ${s.toString().padLeft(2, '0')}s' : '${s}s';
  }
}

/// How many digits have been entered, and never how many there should be.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.dimmed});

  final int count;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return SizedBox(
      height: 14,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dimmed ? t.line : Tone.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBack});

  final void Function(String digit) onDigit;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    Widget key(String label, {VoidCallback? action, IconData? icon}) => SizedBox(
          width: 76,
          height: 66,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: action ?? () => onDigit(label),
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 22, color: t.muted)
                    : Text(label,
                        style: Type.display
                            .copyWith(fontSize: 26, color: t.text)),
              ),
            ),
          ),
        );

    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [for (final d in row) key(d)],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 76),
            key('0'),
            key('', action: onBack, icon: Icons.backspace_outlined),
          ],
        ),
      ],
    );
  }
}
