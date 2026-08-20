/// The first screen: decide whether this device keeps anything.
///
/// # Why this is a choice and not a login
///
/// There is no account to sign in to. The passphrase does one thing: it derives
/// the key that seals what this device writes down.
///
/// Keeping history means writing readable message text to disk, encrypted, in a
/// profile that can be copied. Everywhere else in Rotelyx plaintext exists only
/// in memory for the moment it is on screen. That is a real change to what an
/// attacker with the device gets, so it is opt in and it is explained here
/// rather than buried in settings.
library;

import 'package:flutter/material.dart';

import '../../rotelyx/passphrase.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../brand.dart';
import '../theme.dart';
import '../widgets.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.onReady});

  /// Called once the app may proceed, with or without a vault.
  final VoidCallback onReady;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Whether the passphrase in the field was generated rather than typed.
  ///
  /// Only a generated one has a number attached to it. Guessing at the strength
  /// of something a person invented would mean showing a figure that is not
  /// measured, and a wrong reassurance is worse than none.
  bool _generated = false;
  int _words = defaultWordCount;

  void _generate() {
    setState(() {
      _generated = true;
      _pass.text = generatePassphrase(words: _words);
      _error = null;
    });
  }

  bool get _returning => store.hasVault;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final pass = _pass.text;
    if (pass.length < 8) {
      setState(() => _error =
          'At least 8 characters. What this protects is every conversation on '
          'this device.');
      return;
    }

    setState(() { _busy = true; _error = null; });

    try {
      if (_returning) {
        final ok = await store.unlock(pass);
        if (!ok) {
          setState(() { _busy = false; _error = 'That passphrase does not open this vault.'; });
          return;
        }
      } else {
        await store.create(pass);
      }
      widget.onReady();
    } on Object catch (e) {
      if (mounted) setState(() { _busy = false; _error = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Container(
      color: t.backdrop,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Metrics.wide),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: RxWordmark(height: 104)),
                  const SizedBox(height: Metrics.pad),
                  Text(
                    _returning
                        ? 'Enter your passphrase to open what this device kept.'
                        : 'Peer to peer, end to end encrypted. '
                            'No account, no phone number, no directory.',
                    style: Type.body.copyWith(color: t.muted),
                  ),
                  const SizedBox(height: Metrics.wide),

                  RxField(
                    controller: _pass,
                    label: 'Passphrase',
                    hint: _returning ? 'Your passphrase' : 'At least 8 characters',
                    // A generated passphrase is shown. There is nobody to hide
                    // it from at the moment it is made, and hiding the one
                    // thing the user has to memorise is how it gets lost.
                    obscure: _returning || !_generated,
                    autofocus: true,
                    onSubmit: (_) => _go(),
                    onChanged: (_) {
                      // Edited by hand, so the strength figure no longer
                      // describes what is in the field.
                      if (_generated) setState(() => _generated = false);
                    },
                    help: _returning
                        ? null
                        : 'Deriving the key takes about a second. That delay is '
                            'the point: it is what makes a passphrase worth '
                            'something.',
                  ),

                  if (!_returning) ...[
                    const SizedBox(height: Metrics.gap),
                    _Generator(
                      words: _words,
                      generated: _generated,
                      onGenerate: _generate,
                      onWords: (n) {
                        setState(() => _words = n);
                        if (_generated) _generate();
                      },
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: Metrics.pad),
                    RxNote(_error!, tone: Tone.bad),
                  ],

                  const SizedBox(height: Metrics.pad),
                  RxButton(_returning ? 'Unlock' : 'Create vault',
                      busy: _busy, wide: true, onTap: _busy ? null : _go),

                  if (!_returning) ...[
                    const SizedBox(height: Metrics.gap),
                    RxButton('Continue without keeping anything',
                        weight: Weight.quiet,
                        wide: true,
                        onTap: _busy ? null : widget.onReady),
                    const SizedBox(height: Metrics.wide),
                    const RxNote(
                      'Keeping history writes your messages to this device, '
                      'encrypted under that passphrase. Without it the app still '
                      'works and simply forgets when you close it, which is '
                      'the stronger position and an inconvenient default.',
                      title: 'What the passphrase changes',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Offering to think of a passphrase, and saying what it is worth.
///
/// # Why the strength is a number rather than a colour
///
/// A green bar means nothing. 72 bits means an attacker has to try 2^72
/// passphrases, and each try costs them Argon2id at 64 MiB. Somebody choosing
/// how much to memorise deserves the actual figure.
///
/// # Why the wordlist being public does not matter
///
/// It is a fair question and the answer is arithmetic. The secret is not which
/// words exist, it is which ones came out, and an attacker holding the entire
/// list still faces 4096 raised to the number of words. Hiding the list would
/// change nothing they have to do and would only make the claim unverifiable.
///
/// What does help is more words, which is why the count is adjustable here
/// rather than fixed.
class _Generator extends StatelessWidget {
  const _Generator({
    required this.words,
    required this.generated,
    required this.onGenerate,
    required this.onWords,
  });

  final int words;
  final bool generated;
  final VoidCallback onGenerate;
  final ValueChanged<int> onWords;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: RxButton(
                generated ? 'Another one' : 'Think of one for me',
                weight: Weight.secondary,
                icon: Icons.casino_outlined,
                onTap: onGenerate,
              ),
            ),
          ],
        ),
        if (generated) ...[
          const SizedBox(height: Metrics.gap),
          Row(
            children: [
              Text('Length', style: Type.small.copyWith(color: t.faint)),
              const SizedBox(width: Metrics.gap),
              for (final n in const [4, 5, 6, 8]) ...[
                GestureDetector(
                  onTap: () => onWords(n),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: n == words ? Tone.accent : t.raised,
                      borderRadius: BorderRadius.circular(Metrics.pill),
                    ),
                    child: Text('$n',
                        style: Type.small.copyWith(
                            color: n == words ? Colors.white : t.muted,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
              const Spacer(),
              Text('${entropyBits(words)} bits',
                  style: Type.small.copyWith(
                      color: Tone.accent, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: Metrics.gap),
          const RxNote(
            'Written down nowhere. If this is the passphrase you keep, memorise '
            'it now: there is no account to recover it from and no copy on any '
            'server, which is the same property that makes the conversations '
            'worth having.',
            title: 'Before you go on',
            tone: Tone.warn,
          ),
        ],
      ],
    );
  }
}
