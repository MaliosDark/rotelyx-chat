/// The first screen: decide whether this device keeps anything.
///
/// # Why this is a choice and not a login
///
/// There is no account to sign in to. The password does one thing: it derives
/// the key that seals what this device writes down.
///
/// Keeping history means writing readable message text to disk, encrypted, in a
/// profile that can be copied. Everywhere else in Rotelyx plaintext exists only
/// in memory for the moment it is on screen. That is a real change to what an
/// attacker with the device gets, so it is opt in and it is explained here
/// rather than buried in settings.
///
/// # Why it is two steps
///
/// It used to be one: a password field, with the other option as a quiet link
/// underneath. That put the weight in the wrong place. The field looked like
/// the task and the actual decision looked like a way to skip it, so somebody
/// who did not know what a passphrase was met a form they could not answer
/// before they had seen a single message.
///
/// The decision comes first now, in the words of the outcome rather than the
/// mechanism: do these messages still exist tomorrow. The password appears
/// only after the answer that needs one, where it is the consequence of a
/// choice already made rather than a toll on the way in.
///
/// Nothing about what the password does changed. It is the same derivation and
/// the same vault.
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

  /// Whether the password in the field was generated rather than typed.
  ///
  /// Only a generated one has a number attached to it. Guessing at the strength
  /// of something a person invented would mean showing a figure that is not
  /// measured, and a wrong reassurance is worse than none.
  bool _generated = false;
  int _words = defaultWordCount;

  /// True while the question is on screen, false once a password is being
  /// chosen. Somebody coming back has already answered it.
  late bool _asking = !store.hasVault;

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
          'Use at least 8 characters. This is what locks every conversation '
          'on this device.');
      return;
    }

    setState(() { _busy = true; _error = null; });

    try {
      if (_returning) {
        final ok = await store.unlock(pass);
        if (!ok) {
          setState(() { _busy = false; _error = 'That password does not open what this device kept.'; });
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
              child: AnimatedSize(
                duration: Motion.enter,
                curve: Motion.enterCurve,
                alignment: Alignment.topCenter,
                child: AnimatedSwitcher(
                  duration: Motion.enter,
                  switchInCurve: Motion.enterCurve,
                  switchOutCurve: Motion.enterCurve,
                  // Sliding rather than crossfading, so the second step reads as
                  // somewhere you went and the back arrow reads as a way out.
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(_asking ? -0.04 : 0.04, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _asking ? _choice(t) : _password(t),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Step one: the question, in the words of what happens rather than of how.
  Widget _choice(RotelyxTheme t) {
    return Column(
      key: const ValueKey('choice'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: RxWordmark(height: 104)),
        const SizedBox(height: Metrics.pad),
        Text(
          'Private messages. No account, no phone number, and no directory to '
          'be listed in.',
          style: Type.body.copyWith(color: t.muted),
        ),
        const SizedBox(height: Metrics.wide),

        RxChoice(
          icon: Icons.lock_outline,
          title: 'Keep my chats',
          body: 'They stay on this phone between sessions, behind a password '
              'that is never sent anywhere.',
          onTap: () => setState(() => _asking = false),
        ),
        const SizedBox(height: Metrics.gap),
        // Named rather than described, because it is a mode a person turns on
        // and off and a name is what they will look for again. The body has to
        // do two jobs: say what closing means, since "when I close" on its own
        // does not say what is being closed, and bound what the name promises.
        // Ghost mode elsewhere means other people cannot see you. Here it means
        // this phone writes nothing down, and their copy is untouched.
        RxChoice(
          icon: Icons.auto_delete_outlined,
          title: 'Ghost mode',
          body: 'Nothing is saved on this phone. Quit the app and it is gone '
              'from here, and you are asked again next time. The other person '
              'still keeps their own copy.',
          tone: t.muted,
          onTap: widget.onReady,
        ),

        const SizedBox(height: Metrics.pad),
        Text(
          'Your messages are end to end encrypted either way. This only '
          'decides what stays on this phone.',
          textAlign: TextAlign.center,
          style: Type.small.copyWith(color: t.faint),
        ),
      ],
    );
  }

  /// Step two, and the whole screen for somebody coming back.
  Widget _password(RotelyxTheme t) {
    return Column(
      key: const ValueKey('password'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_returning) ...[
          const Center(child: RxWordmark(height: 104)),
          const SizedBox(height: Metrics.pad),
          Text('Welcome back. Your password opens what this device kept.',
              style: Type.body.copyWith(color: t.muted)),
        ] else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: _busy ? null : () => setState(() => _asking = true),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.only(bottom: Metrics.pad, right: 40),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_back, size: 18, color: t.muted),
                    const SizedBox(width: 6),
                    Text('Back', style: Type.label.copyWith(color: t.muted)),
                  ],
                ),
              ),
            ),
          ),
          const Text('Pick a password', style: Type.display),
          const SizedBox(height: Metrics.gap),
          Text(
            'It locks the chats this device keeps. Long beats complicated: '
            'four ordinary words are harder to break than one clever word.',
            style: Type.body.copyWith(color: t.muted),
          ),
        ],
        const SizedBox(height: Metrics.wide),

        RxField(
          controller: _pass,
          hint: _returning ? 'Your password' : 'Your new password',
          // A generated password is shown. There is nobody to hide it from at
          // the moment it is made, and hiding the one thing the user has to
          // memorise is how it gets lost.
          obscure: _returning || !_generated,
          autofocus: true,
          onSubmit: (_) => _go(),
          onChanged: (_) {
            // Edited by hand, so the strength figure no longer describes what
            // is in the field.
            if (_generated) setState(() => _generated = false);
          },
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
        RxButton(_returning ? 'Unlock' : 'Continue',
            busy: _busy, wide: true, onTap: _busy ? null : _go),

        if (!_returning) ...[
          const SizedBox(height: Metrics.wide),
          const RxNote(
            'There is no account behind this password and no server holds a '
            'copy, so nobody can reset it for you. Forget it and the chats on '
            'this phone are gone.',
            title: 'Write it somewhere safe',
            tone: Tone.warn,
          ),
        ],
      ],
    );
  }
}

/// Offering to think of a password, and saying what it is worth.
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
                generated ? 'Another one' : 'Make one up for me',
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
            'Copy it down before you continue. The words come from a public '
            'list, which is fine: the secret is which ones came out, not which '
            'ones exist.',
            title: 'This one is not stored anywhere',
          ),
        ],
      ],
    );
  }
}
