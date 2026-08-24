/// Settings.
///
/// Everything here is local. There is no remote configuration and no mechanism
/// to add one: a server that can change how the client behaves is a server that
/// can turn its protections off.
library;

import 'package:flutter/material.dart';

import '../../platform/biometrics.dart';
import '../../rotelyx/alerts.dart';
import '../../rotelyx/lock.dart';
import '../../rotelyx/push.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/rotelyx_config.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../../rotelyx/rotelyx_wasm.dart';
import '../brand.dart';
import '../theme.dart';
import '../widgets.dart';
import 'pin_set.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.onClose,
    required this.onWiped,
    required this.dark,
    required this.onTheme,
  });

  final VoidCallback onClose;
  final VoidCallback onWiped;
  final bool dark;
  final ValueChanged<bool> onTheme;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Whether the system will actually show anything.
  ///
  /// Read from the platform rather than remembered, because it can be turned
  /// off in system settings without this application being told, and a switch
  /// that claims notifications are on when the system has them off is worse
  /// than no switch.
  bool _notify = false;

  /// Whether the background connection is being held.
  bool _connected = false;

  /// Whether this device has a fingerprint enrolled.
  bool _canBiometric = false;

  @override
  void initState() {
    super.initState();
    alerts.showContentOnLockScreen = store.showPreviews;
    _connected = store.stayConnected;
    biometricsAvailable().then((can) {
      if (mounted) setState(() => _canBiometric = can);
    });
    alerts.permitted().then((yes) {
      if (mounted) setState(() => _notify = yes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final ready = RotelyxWasm.isReady;

    return Container(
      color: t.backdrop,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: Metrics.gap, vertical: Metrics.gap),
              child: Row(children: [
                IconButton(
                    onPressed: widget.onClose,
                    icon: Icon(Icons.arrow_back, size: 20, color: t.muted)),
                Text('Settings', style: Type.title.copyWith(color: t.text)),
              ]),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: ListView(
                padding: const EdgeInsets.all(Metrics.pad),
                children: [
                  const _Section('Appearance'),
                  SwitchListTile(
                    value: widget.dark,
                    onChanged: widget.onTheme,
                    activeColor: Tone.accent,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Dark theme',
                        style: Type.body.copyWith(color: t.text)),
                  ),

                  const SizedBox(height: Metrics.pad),
                  const _Section('Notifications'),
                  SwitchListTile(
                    value: _notify,
                    onChanged: (want) async {
                      if (want && !await alerts.request()) {
                        // Refused, and on Android 13 and later a refusal
                        // cannot be asked about again from here. Saying so
                        // beats a switch that flips back with no explanation.
                        if (!context.mounted) return;
                        setState(() => _notify = false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Android is refusing notifications for this '
                                'app. Turn them on in system settings.'),
                          ),
                        );
                        return;
                      }
                      setState(() => _notify = want);
                    },
                    activeColor: Tone.accent,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Notify me about messages',
                        style: Type.body.copyWith(color: t.text)),
                    subtitle: Text('Posted by this app, on this device',
                        style: Type.small.copyWith(color: t.faint)),
                  ),
                  SwitchListTile(
                    value: alerts.showContentOnLockScreen,
                    onChanged: _notify
                        ? (want) => setState(() {
                              alerts.showContentOnLockScreen = want;
                              store.showPreviews = want;
                            })
                        : null,
                    activeColor: Tone.accent,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Show the message on a locked screen',
                        style: Type.body.copyWith(color: t.text)),
                    subtitle: Text(
                        alerts.showContentOnLockScreen
                            ? 'Anyone who can see your screen can read it'
                            : 'Only who it is from',
                        style: Type.small.copyWith(color: t.faint)),
                  ),
                  if (alerts.canStayConnected)
                    SwitchListTile(
                      value: _connected,
                      onChanged: (want) async {
                        final on = await alerts.stayConnected(want);
                        if (mounted) setState(() => _connected = on);
                      },
                      activeColor: Tone.accent,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Receive while the app is closed',
                          style: Type.body.copyWith(color: t.text)),
                      subtitle: Text(
                          !_connected
                              ? 'Off: messages arrive when you open the app'
                              : rotelyx.canBeWoken
                                  ? 'Apple wakes this device on a fixed '
                                      'schedule and learns only that, never '
                                      'when a message arrived'
                                  : 'Shows a permanent notice and uses battery',
                          style: Type.small.copyWith(color: t.faint)),
                    ),

                  const SizedBox(height: Metrics.gap),
                  const RxNote(
                    'Nothing is registered with Google or Apple. This app holds '
                    'its own connection to the mailbox, so a message is '
                    'decrypted here before you are told about it, and no push '
                    'service learns that one arrived.',
                    title: 'Who tells you',
                  ),

                  const SizedBox(height: Metrics.pad),
                  const _Section('Lock'),
                  SwitchListTile(
                    value: lock.isSet,
                    onChanged: (want) async {
                      if (!want) {
                        lock.setPin('');
                        if (mounted) setState(() {});
                        return;
                      }
                      final pin = await SetPinSheet.ask(context);
                      if (pin != null) lock.setPin(pin);
                      if (mounted) setState(() {});
                    },
                    activeColor: Tone.accent,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Ask for a PIN to open the app',
                        style: Type.body.copyWith(color: t.text)),
                    subtitle: Text(
                        lock.isSet
                            ? 'Asked for at launch and after you have been away'
                            : 'Off. Anyone holding this phone can open it',
                        style: Type.small.copyWith(color: t.faint)),
                  ),
                  if (lock.isSet && _canBiometric)
                    SwitchListTile(
                      value: store.useBiometric,
                      onChanged: (want) =>
                          setState(() => store.useBiometric = want),
                      activeColor: Tone.accent,
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(Icons.fingerprint,
                          size: 20,
                          color: store.useBiometric ? Tone.accent : t.muted),
                      title: Text('Use your fingerprint instead of typing it',
                          style: Type.body.copyWith(color: t.text)),
                      subtitle: Text(
                          'A shortcut to the PIN, not a replacement for it',
                          style: Type.small.copyWith(color: t.faint)),
                    ),
                  if (lock.isSet)
                    TextButton(
                      onPressed: () async {
                        final pin = await SetPinSheet.ask(context);
                        if (pin != null) lock.setPin(pin);
                        if (mounted) setState(() {});
                      },
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      child: Text('Change the PIN',
                          style: Type.body.copyWith(color: Tone.accent)),
                    ),
                  const SizedBox(height: Metrics.gap),
                  const RxNote(
                    'A PIN is short, and nothing changes that. Four digits is '
                    'ten thousand possibilities, so this device makes each '
                    'guess slow rather than pretending the number is large: it '
                    'stretches the PIN the same way it stretches your '
                    'passphrase, and stops answering for five minutes after ten '
                    'wrong tries. It is a lock against somebody who picked up '
                    'your phone. It is not a lock against somebody who took it '
                    'away with a laboratory. Your passphrase is what protects '
                    'the messages themselves.',
                    title: 'What a PIN does and does not do',
                  ),

                  const SizedBox(height: Metrics.pad),
                  const _Section('This device'),
                  _Row('History',
                      store.isUnlocked ? 'Kept, encrypted' : 'Not kept'),
                  _Row('Conversations', '${store.conversationIds.length}'),
                  const SizedBox(height: Metrics.gap),
                  const RxNote(
                    'The mailbox keeps nothing. An envelope is removed when it '
                    'is collected and what is never collected expires, so this '
                    'device holds the only copy of anything you can still read.',
                    title: 'Where your messages live',
                  ),

                  const SizedBox(height: Metrics.pad),
                  const _Section('Protocol'),
                  _Row('Version', ready ? RotelyxWasm.protocolVersion : 'not loaded'),
                  const _Row('Key agreement', 'X-Wing · ML-KEM-768 + X25519'),
                  const _Row('Message layer', 'MLS'),
                  _Row('Largest group', ready ? '${RotelyxWasm.maxMembers}' : 'not loaded'),
                  _Row('Mailbox', Uri.parse(rotelyxConfig.mailbox).host),
                  // Users deserve to know whether Google is in the path of a
                  // notification, so the transport is named rather than assumed.
                  _Row('Wake service', pushTransport.name),

                  const SizedBox(height: Metrics.gap),
                  const RxNote(
                    'Calls are always relayed, and that is deliberate. On a '
                    'direct path the other participants learn your address, so '
                    'for a call the exposure that matters is to whoever is on '
                    'it rather than to a server. There is no switch for this.',
                    title: 'Why calls are slower',
                  ),

                  const SizedBox(height: Metrics.pad),
                  const _Section('About'),
                  const _Vendor(),

                  const SizedBox(height: Metrics.pad),
                  const _Section('Danger'),
                  RxButton('Delete everything on this device',
                      weight: Weight.secondary,
                      icon: Icons.delete_outline,
                      wide: true,
                      onTap: () => _confirmWipe(context)),

                  const SizedBox(height: Metrics.wide),
                  const RxNote(
                    'Rotelyx is unaudited and pre-release. It makes no security '
                    'claims until an independent cryptographic review is '
                    'complete. Do not use it to protect anything.',
                    tone: Tone.warn,
                  ),
                ],
              ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmWipe(BuildContext context) async {
    final t = RotelyxThemeScope.of(context);

    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('Delete everything?', style: Type.title.copyWith(color: t.text)),
        content: Text(
          'Every conversation on this device goes. There is no server copy and '
          'no way to recover them.',
          style: Type.body.copyWith(color: t.muted),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Keep', style: Type.label.copyWith(color: t.muted))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete', style: Type.label.copyWith(color: Tone.bad))),
        ],
      ),
    );

    if (yes == true) {
      store.wipe();
      widget.onWiped();
    }
  }
}

/// Who made this.
///
/// Here rather than on the boot screen. A splash is the product's own name and
/// nothing else; the company behind it is something a person looks for when
/// they want it, which is what a settings screen is for.
///
/// The mark is Rotelyx's. Ideoa Labs has no artwork in this repository, so its
/// name is set rather than drawn, and swapping in a logo is one widget here.
class _Vendor extends StatelessWidget {
  const _Vendor();

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Container(
      padding: const EdgeInsets.all(Metrics.pad),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(Metrics.radius),
        border: Border.all(color: t.line),
      ),
      child: Row(
        children: [
          const RxMark(size: 40, radius: 10),
          const SizedBox(width: Metrics.pad),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Rotelyx Chat', style: Type.label.copyWith(color: t.text)),
                const SizedBox(height: 2),
                Text('by Ideoa Labs',
                    style: Type.small.copyWith(color: t.muted)),
              ],
            ),
          ),
          const RxChip('pre-release', tone: Tone.warn),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Metrics.gap),
      child: Text(title.toUpperCase(),
          style: Type.small.copyWith(
              color: t.faint, fontWeight: FontWeight.w700, letterSpacing: 1)),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: Type.body.copyWith(color: t.muted)),
          ),
          Expanded(
            child: SelectableText(value,
                style: Type.body.copyWith(color: t.text)),
          ),
        ],
      ),
    );
  }
}
