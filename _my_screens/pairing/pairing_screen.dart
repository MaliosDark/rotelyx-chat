/// Pairing: how two devices that have never met establish a conversation.
///
/// Rotelyx has no identity registry, so there is no directory to look someone
/// up in and no phone number to address them by. Two people who have never
/// exchanged a key have nowhere to put the first message, and both modes here
/// solve exactly that and nothing more:
///
///   **Meeting phrase**: both sides type the same phrase; it hashes to a
///   mailbox tag they can both compute. Convenient, and guessable: whoever
///   arrives first answers.
///
///   **Invitation code**: one side generates a code carrying its key package
///   and a random 32-byte return tag, delivered out of band. Nothing to guess.
///
/// Neither authenticates anybody. That is what the safety number is for, and
/// why the chat screen puts it on the wall rather than behind a menu.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../config.dart';
import '../../rotelyx/rotelyx_wasm.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  final _name = TextEditingController();
  final _phrase = TextEditingController();
  final _code = TextEditingController();

  /// The invitation this device generated, if it is the one waiting.
  String? _invitation;

  bool _busy = false;
  String? _error;

  StreamSubscription<RotelyxState>? _states;

  @override
  void initState() {
    super.initState();
    _name.text = appCtrl.displayName;

    _states = rotelyx.stateChanges.listen((state) {
      if (!mounted) return;
      if (state == RotelyxState.joined) {
        Get.offNamed(routeName.chat);
      } else if (state == RotelyxState.failed) {
        setState(() {
          _busy = false;
          _error = rotelyx.lastError;
        });
      }
    });
  }

  @override
  void dispose() {
    // The service outlives this screen, it is a singleton holding the MLS
    // group, so a subscription left open here fires setState on a disposed
    // State every time pairing is retried.
    _states?.cancel();
    _tabs.dispose();
    _name.dispose();
    _phrase.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Runs a pairing action, surfacing failures in the one place the user is
  /// looking. Silence here used to mean a spinner that never stopped.
  Future<void> _attempt(Future<void> Function() action) async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'choose a name others will see first');
      return;
    }
    appCtrl.setDisplayName(_name.text.trim());
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // Wait for the module rather than refusing the tap. Two megabytes of wasm
      // routinely finish after the first paint, and telling someone to try
      // again for something that was only early is a bad way to be correct.
      await RotelyxWasm.whenReady();
      await action();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  /// What the screen is doing while `_busy`, in words.
  ///
  /// The host waits indefinitely by design, someone has to be there first,
  /// and a dimmed button with no explanation reads as a hang.
  String get _waitingLabel => switch (rotelyx.state) {
        RotelyxState.pairing when _role == PairingRole.host =>
          'Waiting at the meeting place. Have the other person join with the '
              'same phrase.',
        RotelyxState.pairing => 'Knocking. Waiting for the other side to answer.',
        _ => 'Loading the Rotelyx module…',
      };

  PairingRole? _role;

  @override
  Widget build(BuildContext context) {
    final theme = appCtrl.appTheme;

    return Scaffold(
      backgroundColor: theme.screenBG,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(theme),
                  const SizedBox(height: 28),
                  if (_busy && _invitation == null)
                    _waiting(theme)
                  else ...[
                    _nameField(theme),
                    const SizedBox(height: 20),
                    _tabBar(theme),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 300,
                      child: TabBarView(
                        controller: _tabs,
                        children: [_phraseMode(theme), _codeMode(theme)],
                      ),
                    ),
                  ],
                  if (_error != null) _errorBox(theme, _error!),
                  const SizedBox(height: 20),
                  _unauditedNotice(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppTheme theme) => Column(
        children: [
          // The real wordmark rather than styled text, so this reads as the same
          // product as the protocol repository and the site.
          Image.asset(
            appCtrl.isTheme ? eImageAssets.wordmarkDark : eImageAssets.wordmarkLight,
            height: 52,
            // A missing asset renders as an empty box and silently loses the
            // product name, so fall back to the name in text.
            errorBuilder: (_, __, ___) => Text('Rotelyx Chat',
                style: TextStyle(
                    fontFamily: appFontFamily,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: theme.darkText)),
          ),
          const SizedBox(height: 10),
          Text('Peer to peer, end to end encrypted. No account, no directory.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: theme.greyText)),
        ],
      );

  Widget _nameField(AppTheme theme) => TextField(
        controller: _name,
        style: TextStyle(color: theme.darkText),
        decoration: InputDecoration(
          labelText: 'Your name',
          helperText: 'A label others see. It proves nothing on its own.',
          helperStyle: TextStyle(color: theme.greyText, fontSize: 11),
          filled: true,
          fillColor: theme.textField,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );

  Widget _tabBar(AppTheme theme) => Container(
        decoration: BoxDecoration(
            color: theme.boxBg, borderRadius: BorderRadius.circular(12)),
        child: TabBar(
          controller: _tabs,
          dividerColor: Colors.transparent,
          // Without this the indicator is sized to the label's own width and the
          // longer of the two ("Meeting phrase") spills past its pill.
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorPadding: const EdgeInsets.all(4),
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          indicator: BoxDecoration(
              color: theme.primary, borderRadius: BorderRadius.circular(12)),
          labelColor: theme.sameWhite,
          unselectedLabelColor: theme.greyText,
          tabs: const [Tab(text: 'Meeting phrase'), Tab(text: 'Invitation')],
        ),
      );

  // ---------------------------------------------------------------------------
  // Mode one: a phrase both sides already know
  // ---------------------------------------------------------------------------

  Widget _phraseMode(AppTheme theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _phrase,
            style: TextStyle(color: theme.darkText),
            decoration: InputDecoration(
              labelText: 'Shared phrase',
              hintText: 'at least 8 characters',
              filled: true,
              fillColor: theme.textField,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Agree this over a channel you already trust. Anyone who learns it '
            'before the other person arrives can answer in their place, check '
            'the safety number once you are connected.',
            style: TextStyle(fontSize: 11, color: theme.greyText, height: 1.5),
          ),
          const Spacer(),
          Row(children: [
            Expanded(
              child: _button(
                theme,
                label: 'Wait here',
                filled: true,
                onTap: () {
                  _role = PairingRole.host;
                  _attempt(() => rotelyx.pairByPhrase(
                        phrase: _phrase.text,
                        displayName: _name.text.trim(),
                        role: PairingRole.host,
                      ));
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _button(
                theme,
                label: 'Join',
                filled: false,
                onTap: () {
                  _role = PairingRole.guest;
                  _attempt(() => rotelyx.pairByPhrase(
                        phrase: _phrase.text,
                        displayName: _name.text.trim(),
                        role: PairingRole.guest,
                      ));
                },
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text('One side waits, the other joins.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: theme.greyText)),
        ],
      );

  // ---------------------------------------------------------------------------
  // Mode two: an invitation delivered out of band
  // ---------------------------------------------------------------------------

  Widget _codeMode(AppTheme theme) {
    if (_invitation != null) return _showInvitation(theme, _invitation!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _button(
          theme,
          label: 'Create an invitation',
          filled: true,
          onTap: () => _attempt(() async {
            final code =
                await rotelyx.createInvitation(displayName: _name.text.trim());
            if (mounted) setState(() => _invitation = code);
          }),
        ),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: Divider(color: theme.divider)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('or paste one',
                style: TextStyle(fontSize: 11, color: theme.greyText)),
          ),
          Expanded(child: Divider(color: theme.divider)),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: _code,
          maxLines: 3,
          style: TextStyle(color: theme.darkText, fontSize: 11),
          decoration: InputDecoration(
            hintText: 'paste an invitation code here',
            filled: true,
            fillColor: theme.textField,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 12),
        _button(
          theme,
          label: 'Accept invitation',
          filled: false,
          onTap: () => _attempt(() => rotelyx.acceptInvitation(
                code: _code.text,
                displayName: _name.text.trim(),
              )),
        ),
      ],
    );
  }

  Widget _showInvitation(AppTheme theme, String code) => Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: QrImageView(data: code, size: 150, version: QrVersions.auto),
          ),
          const SizedBox(height: 12),
          Text('Waiting for someone to accept this.',
              style: TextStyle(fontSize: 12, color: theme.darkText)),
          const SizedBox(height: 4),
          Text(
            'The code is public, it carries no secret. Send it however you '
            'like.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: theme.greyText),
          ),
          const Spacer(),
          _button(
            theme,
            label: 'Copy code',
            filled: false,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invitation copied')));
              }
            },
          ),
        ],
      );

  // ---------------------------------------------------------------------------

  Widget _button(AppTheme theme,
          {required String label,
          required bool filled,
          required VoidCallback onTap}) =>
      Opacity(
        opacity: _busy ? 0.5 : 1,
        child: Material(
          color: filled ? theme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _busy ? null : onTap,
            child: Container(
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: filled ? null : Border.all(color: theme.primary),
              ),
              child: Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: filled ? theme.sameWhite : theme.primary)),
            ),
          ),
        ),
      );

  /// Shown instead of the form while a pairing attempt is outstanding.
  Widget _waiting(AppTheme theme) => Column(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: theme.primary),
          ),
          const SizedBox(height: 20),
          Text(_waitingLabel,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 13, color: theme.darkText, height: 1.5)),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => setState(() {
              _busy = false;
              _error = null;
              _role = null;
            }),
            child: Text('Cancel', style: TextStyle(color: theme.greyText)),
          ),
        ],
      );

  Widget _errorBox(AppTheme theme, String message) => Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: theme.redColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10)),
        child: Text(message,
            style: TextStyle(fontSize: 12, color: theme.redColor)),
      );

  /// The repository says this in bold and so does this screen.
  ///
  /// A chat client that looks finished is itself a security claim, which is the
  /// one thing the threat model says cannot be made yet.
  Widget _unauditedNotice(AppTheme theme) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            border: Border.all(color: theme.borderColor),
            borderRadius: BorderRadius.circular(10)),
        child: Text(
          'Rotelyx is unaudited and pre-release. It makes no security claims '
          'until an independent cryptographic review is complete. Do not use it '
          'to protect anything.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: theme.greyText, height: 1.5),
        ),
      );
}
