/// Settings.
///
/// Everything here is local. There is no remote configuration and no mechanism
/// to add one: a server that can change how the client behaves is a server that
/// can turn its protections off.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../platform/apple_push.dart';
import '../../platform/biometrics.dart';
import '../../platform/os.dart' as os;
import '../../platform/widgets.dart';
import '../../rotelyx/mailboxes.dart';
import '../../rotelyx/alerts.dart';
import '../../rotelyx/lock.dart';
import '../../rotelyx/push.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/rotelyx_config.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../../rotelyx/chosen_name.dart';
import '../../rotelyx/rotelyx_wasm.dart';
import '../../rotelyx/signal.dart';
import 'picture.dart';
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
  /// The name this person goes by, for the next conversation they start.
  ///
  /// It lived only on the pairing screen, which meant it was typed or accepted
  /// again on the way into every conversation and there was nowhere to look at
  /// it, change it, or keep it. `RotelyxStore.myName` was already written there
  /// and already read back as the default; what was missing was a place to set
  /// it on purpose.
  late final TextEditingController _myName =
      TextEditingController(text: store.myName ?? '');

  @override
  void dispose() {
    _myName.dispose();
    super.dispose();
  }

  /// Whether the system will actually show anything.
  ///
  /// Read from the platform rather than remembered, because it can be turned
  /// off in system settings without this application being told, and a switch
  /// that claims notifications are on when the system has them off is worse
  /// than no switch.
  bool _notify = false;

  /// Whether this device asked to be woken the moment something arrives.
  ///
  /// The inverse of what is stored: the setting is written as "on a schedule",
  /// which is the private default, and the switch is phrased as the thing a
  /// person wants rather than as the mechanism.
  bool _immediate = !rotelyx.wakeOnSchedule;

  /// What the notification extension did the last time a push arrived.
  ///
  /// Read once when this screen opens. It changes only when a wake happens,
  /// which is not while somebody is looking at this list.
  LastWake? _lastWake;

  /// How long ago, in the roughest terms that are still useful.
  static String _ago(DateTime at) {
    final since = DateTime.now().difference(at);
    if (since.inMinutes < 1) return 'Just now';
    if (since.inMinutes < 60) return '${since.inMinutes} minutes ago';
    if (since.inHours < 24) return '${since.inHours} hours ago';
    return '${since.inDays} days ago';
  }

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
    lastWake().then((wake) {
      if (mounted) setState(() => _lastWake = wake);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final ready = RotelyxWasm.isReady;

    return Container(
      // The ground, which is a light falling from one corner rather than a
      // flat fill. Painted here rather than left to the root because this
      // screen used to paint its own colour over it, which is why the first
      // two attempts at this were invisible on every screen that mattered.
      decoration: groundOf(t.backdrop),
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
                  // Folded rather than laid out end to end.
                  //
                  // This screen had eight headings and nine hundred lines on
                  // one scroll, which is a list nobody reads and everybody
                  // hunts through. `_Fold` was already here and already used
                  // for the dense half; this is the same idiom applied to the
                  // rest, so the screen opens as a page of titles and each one
                  // opens where it stands. Nothing was removed.
                  // You, as the other side sees you.
                  //
                  // First, because it is the only thing on this screen that
                  // other people see, and because until now there was nowhere
                  // at all to change it: the only picker in the application sat
                  // on a contact's card and wrote the contact's face.
                  const _Section('You'),

                  _Fold(
                    title: 'Your name',
                    summary: (store.myName ?? '').isEmpty
                        ? 'Made up for you each time'
                        : store.myName!,
                    children: [
                      RxField(
                        controller: _myName,
                        label: 'Your name',
                        hint: 'Anything you like',
                        help: 'What the people you pair with see. Only a label, '
                            'and anyone can pick any of them: it is not how '
                            'somebody knows who they are talking to.',
                        onChanged: (v) => setState(() {
                          // Written as it is typed rather than on a save
                          // button, because a name people have to remember to
                          // save is a name that is half saved.
                          store.myName = v.trim();
                        }),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() {
                            // The generator is still here for anybody who
                            // would rather not choose, which is what the
                            // pairing screen offered and what this would have
                            // taken away.
                            final made = suggestName();
                            _myName.text = made;
                            store.myName = made;
                          }),
                          icon: Icon(Icons.casino_outlined,
                              size: 16, color: t.muted),
                          label: Text('Make one up for me',
                              style: Type.small.copyWith(color: t.muted)),
                        ),
                      ),
                    ],
                  ),

                  _Fold(
                    title: 'Your picture',
                    summary: store.myPicture == null
                        ? 'Drawn from your name'
                        : 'A picture you chose',
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            PicturePicker(
                              name: store.myName ?? 'anon',
                              onChanged: () => setState(() {}),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                'It travels with what you send, so a message '
                                'is recognisable as yours. Nobody fetches it '
                                'from anywhere: it goes to the people you are '
                                'already talking to and nowhere else.',
                                style: Type.small.copyWith(color: t.faint),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (store.myPicture != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () {
                              setState(() => store.myPicture = null);
                              rotelyx.signal(Signal.profile(Uint8List(0)));
                            },
                            child: Text('Go back to the drawn one',
                                style: Type.small.copyWith(color: t.muted)),
                          ),
                        ),
                    ],
                  ),

                  const _Section('This phone'),
                  _Fold(
                    title: 'Appearance',
                    summary: widget.dark ? 'Dark' : 'Light',
                    children: [
                      SwitchListTile(
                        value: widget.dark,
                        onChanged: widget.onTheme,
                        activeThumbColor: Tone.accent,
                        contentPadding: EdgeInsets.zero,
                        title: Text('Dark theme',
                            style: Type.body.copyWith(color: t.text)),
                      ),
                    ],
                  ),

                  _Fold(
                    title: 'Notifications',
                    summary: _notify
                        ? 'On for messages'
                        : 'Off: nothing interrupts you',
                    children: [
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
                                'Notifications are switched off for this app. '
                                'Turn them on in your phone settings.'),
                          ),
                        );
                        return;
                      }
                      setState(() => _notify = want);
                    },
                    activeThumbColor: Tone.accent,
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
                    activeThumbColor: Tone.accent,
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
                        if (!context.mounted) return;
                        setState(() => _connected = on);

                        // A switch that turns itself back off and says nothing
                        // is the worst of both: the feature does not work and
                        // the person cannot find out why. The commonest reason
                        // is a mailbox started without a push key, which is
                        // the operator's to fix and not theirs.
                        if (want && !on) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(
                            content: Text(
                                'This mailbox does not offer delivery while '
                                'the app is closed. Messages arrive when you '
                                'open it.'),
                          ));
                        }
                      },
                      activeThumbColor: Tone.accent,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Receive while the app is closed',
                          style: Type.body.copyWith(color: t.text)),
                      subtitle: Text(
                          !_connected
                              ? 'Off: messages arrive when you open the app'
                              : rotelyx.canBeWoken
                                  ? 'Your phone is woken to look. What arrived '
                                      'is read here, on this device'
                                  : 'Shows a permanent notice and uses battery',
                          style: Type.small.copyWith(color: t.faint)),
                    ),

                  // Only where a third party carries the wake, and only once
                  // the switch above is on. On a platform that holds its own
                  // connection there is no rhythm to give away and nothing to
                  // choose between.
                  if (alerts.canStayConnected && _connected && rotelyx.canBeWoken)
                    SwitchListTile(
                      value: _immediate,
                      onChanged: (want) async {
                        store.wakeOnSchedule = !want;
                        setState(() => _immediate = want);
                        // Registered again so the mailbox is told, rather than
                        // waiting for whenever this device next registers.
                        await rotelyx.askToBeWoken();
                      },
                      activeThumbColor: Tone.accent,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Notify me as soon as it arrives',
                          style: Type.body.copyWith(color: t.text)),
                      subtitle: Text(
                          _immediate
                              ? 'On: you are told the moment a message lands'
                              : 'Off: your phone checks on a regular rhythm, '
                                  'shared with every other phone, so yours '
                                  'cannot be told apart by when it checks',
                          style: Type.small.copyWith(color: t.faint)),
                    ),

                  // What the last wake actually did.
                  //
                  // A notification extension runs for seconds in a process
                  // nobody is watching and then dies, so when one shows the
                  // wrong thing there is nothing left to look at. Working out
                  // why turned into two people guessing, for days, about one
                  // blank notification. This is the note it leaves behind.
                  //
                  // Shown only once there is one, so nobody is given a line
                  // about plumbing they never asked about.
                  if (_lastWake != null) ...[
                    const SizedBox(height: Metrics.gap),
                    RxNote(
                      '${_lastWake!.said}\n\n'
                      '${_ago(_lastWake!.at)}, '
                      '${_lastWake!.decoy ? 'on the mailbox schedule' : 'carrying a message'}.',
                      title: 'The last time a push woke this phone',
                      tone: _lastWake!.wasBlank ? Tone.warn : Tone.good,
                    ),
                  ],

                  const SizedBox(height: Metrics.gap),
                  // Two platforms, two true answers, and the difference is the
                  // whole point of the note: on one there is no third party at
                  // all, on the other there is Apple and saying so is the
                  // reason this switch is worth trusting. `canBeWoken` is the
                  // condition rather than the platform, because it is the
                  // condition that makes the second paragraph true.
                  RxNote(
                    rotelyx.canBeWoken
                        ? 'Your phone is woken to go and look. What wakes it '
                            'carries no message and cannot read one: the '
                            'message is collected and opened here, on this '
                            'device. The mailbox never learns which phone '
                            'belongs to which conversation.'
                        : 'This app keeps its own connection to the mailbox, so '
                            'a message is opened on this phone before you are '
                            'told about it, and nothing beyond this device '
                            'learns that one arrived.',
                    title: 'Who tells you',
                  ),
                    ],
                  ),

                  // iOS only. Android has widgets and no complications, and a
                  // setting for a face that does not exist is a setting that
                  // makes somebody look for a feature they do not have.
                  if (os.isIOS)
                    _Fold(
                      title: 'Apple Watch',
                      summary: switch (store.faceDetail) {
                        FaceDetail.nothing => 'The face shows nothing',
                        FaceDetail.count => 'The face shows how many',
                        FaceDetail.name => 'The face shows who',
                      },
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: Metrics.gap),
                          child: Text(
                            'A watch face is on without being unlocked and it '
                            'is pointed at whoever is opposite you. Choose how '
                            'much of it they get to read.\n\n'
                            'The conversation itself is never on the face. '
                            'What you decide here is all that leaves this '
                            'phone for the watch.',
                            style: Type.small.copyWith(color: t.faint),
                          ),
                        ),
                        RadioGroup<FaceDetail>(
                          groupValue: store.faceDetail,
                          onChanged: (picked) {
                            if (picked == null) return;
                            setState(() => store.faceDetail = picked);
                          },
                          child: Column(children: [
                            for (final choice in FaceDetail.values)
                              RadioListTile<FaceDetail>(
                                value: choice,
                                activeColor: Tone.accent,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  switch (choice) {
                                    FaceDetail.nothing => 'Nothing',
                                    FaceDetail.count => 'How many are waiting',
                                    FaceDetail.name => 'How many, and who',
                                  },
                                  style: Type.body.copyWith(color: t.text),
                                ),
                                subtitle: Text(
                                  switch (choice) {
                                    FaceDetail.nothing =>
                                      'Just the mark, as a way back in',
                                    FaceDetail.count =>
                                      'A number. Nobody learns who it is with',
                                    FaceDetail.name =>
                                      'A glance at your wrist reads the name',
                                  },
                                  style: Type.small.copyWith(color: t.faint),
                                ),
                              ),
                          ]),
                        ),
                      ],
                    ),

                  if (os.isIOS)
                    _Fold(
                      title: 'Widgets',
                      summary: switch ((store.homeWidgetDetail,
                          store.lockWidgetDetail)) {
                        (FaceDetail.nothing, FaceDetail.nothing) => 'Off',
                        (_, FaceDetail.nothing) => 'Home screen only',
                        _ => 'On, including the lock screen',
                      },
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: Metrics.gap),
                          child: Text(
                            'Two screens, two decisions. Your home screen is '
                            'behind your passcode, so whoever is looking at it '
                            'could open the app anyway. Your lock screen is '
                            'read by whoever your phone is lying in front '
                            'of.\n\n'
                            'The conversation itself is never on either. What '
                            'you refuse here is not hidden from the widget, it '
                            'is never given to it.',
                            style: Type.small.copyWith(color: t.faint),
                          ),
                        ),
                        _WidgetChoice(
                          title: 'On the home screen',
                          value: store.homeWidgetDetail,
                          onPick: (v) =>
                              setState(() {
                            store.homeWidgetDetail = v;
                            refreshWidgets();
                          }),
                          t: t,
                        ),
                        const SizedBox(height: Metrics.gap),
                        _WidgetChoice(
                          title: 'On the lock screen',
                          value: store.lockWidgetDetail,
                          onPick: (v) =>
                              setState(() {
                            store.lockWidgetDetail = v;
                            refreshWidgets();
                          }),
                          t: t,
                        ),
                      ],
                    ),

                  _Fold(
                    title: 'Lock',
                    summary: lock.isSet
                        ? 'A PIN is asked for'
                        : 'Anyone holding this phone can open it',
                    children: [
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
                    activeThumbColor: Tone.accent,
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
                      activeThumbColor: Tone.accent,
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
                    'Four digits is ten thousand possibilities, so instead '
                    'of pretending that is a lot, this device makes every '
                    'guess slow and stops answering for five minutes after ten '
                    'wrong ones. It locks out somebody who picked up your '
                    'phone. It does not lock out somebody who took it away to '
                    'a laboratory. Your password is what protects the messages '
                    'themselves.',
                    title: 'What a PIN does and does not do',
                  ),
                    ],
                  ),

                  _Fold(
                    title: 'This device',
                    summary: '${store.conversationIds.length} conversations',
                    children: [
                  _Row('History',
                      store.isUnlocked ? 'Kept, encrypted' : 'Not kept'),
                  _Row('Conversations', '${store.conversationIds.length}'),
                  const SizedBox(height: Metrics.gap),
                  const RxNote(
                    'The server keeps nothing. A message is deleted the '
                    'moment it is collected, and anything never collected '
                    'expires on its own. This phone holds the only copy of '
                    'anything you can still read.',
                    title: 'Where your messages live',
                  ),
                    ],
                  ),

                  const SizedBox(height: Metrics.pad),
                  // Everything above this line is something somebody changes
                  // about their own phone. Everything below it is what the
                  // application is doing and how, which is worth being able to
                  // read and is not worth scrolling past every time.
                  //
                  // They were all one list until 2 September 2026, nine
                  // sections deep, and three of them were diagnostics. What
                  // that reads as is a settings screen with a developer's
                  // console mixed into it, and the effect is that the settings
                  // people actually came for are harder to find.
                  const _Section('Privacy and protocol'),
                  _Fold(
                    title: 'Where your messages wait',
                    summary: 'The mailbox that holds them until you collect',
                    children: [
                      _MailboxPicker(onChanged: () => setState(() {})),
                    ],
                  ),
                  const _Fold(
                    title: 'How your messages are protected',
                    summary: 'Built to hold up even against a quantum computer',
                    children: [
                      _Row('Key agreement', 'X-Wing · ML-KEM-768 + X25519'),
                      _Row('Message layer', 'MLS'),
                      SizedBox(height: Metrics.gap),
                      RxNote(
                        'Two separate key exchanges, one of them designed to '
                        'survive a computer that does not exist yet. Anything '
                        'recorded today stays unreadable if one is broken '
                        'later, which is the point: a message taken now can be '
                        'kept for twenty years before anyone tries.',
                        title: 'What that means',
                      ),
                    ],
                  ),
                  _Fold(
                    title: 'Who is in the path',
                    summary: 'Named rather than assumed',
                    children: [
                      _Row('Mailbox', Uri.parse(rotelyxConfig.mailbox).host),
                      // Whether anything outside this device sits in the path
                      // of a notification, named rather than left to be
                      // guessed at.
                      _Row('Wake service', pushTransport.name),
                      const SizedBox(height: Metrics.gap),
                      const RxNote(
                        'Calls always go through a relay, on purpose. A direct '
                        'connection would show the other person your address, '
                        'so the slower path is the one that keeps it to '
                        'yourself. There is no switch for this.',
                        title: 'Why calls take a moment to connect',
                      ),
                    ],
                  ),

                  const SizedBox(height: Metrics.pad),
                  const _Section('Advanced'),
                  _Fold(
                    title: 'Ghost mode',
                    summary: store.isDark
                        ? 'On: nothing is being written down'
                        : 'Stop writing anything down until you quit',
                    children: [
                      if (store.isDark)
                        const RxNote(
                          'Nothing you do is being written to this phone. Your '
                          'conversations are still on it, sealed, and the next '
                          'time you open the app your password brings them '
                          'back.',
                          tone: Tone.good,
                        )
                      else ...[
                        RxButton('Turn on ghost mode',
                            weight: Weight.secondary,
                            icon: Icons.auto_delete_outlined,
                            wide: true,
                            onTap: () => _confirmGoDark(context)),
                        const SizedBox(height: Metrics.gap),
                        const RxNote(
                          'Stops writing anything down until you quit. What is '
                          'already saved stays saved and stays sealed, so this '
                          'deletes nothing, but the history comes off the '
                          'screen while it is on.',
                        ),
                      ],
                    ],
                  ),
                  _Fold(
                    title: 'Build',
                    summary: 'Versions and limits',
                    children: [
                      _Row('Version',
                          ready ? RotelyxWasm.protocolVersion : 'not loaded'),
                      // The largest group was shown here and is not any
                      // more. It is a ceiling rather than a promise, it invites
                      // being read as one, and somebody comparing two
                      // applications on a number compares the wrong thing:
                      // what limits a group here is the cost of one deposit per
                      // member, not a constant.
                    ],
                  ),

                  const SizedBox(height: Metrics.pad),
                  const _Section('About'),

                  // Two rows rather than a fold: a heading called About holding
                  // one fold called Version is the same word twice to hide two
                  // lines.
                  //
                  // They answer different questions and showing only the
                  // protocol's answered neither. The application's is what a
                  // person compares with the store and quotes in a bug report;
                  // the protocol's is what says whether two devices can speak
                  // at all. Both are read from the compile-time defines Flutter
                  // already injects from `pubspec.yaml`, rather than by taking
                  // a dependency to ask the bundle what the build knows.
                  _Row('Application', _appVersion),
                  _Row('Protocol',
                      ready ? RotelyxWasm.protocolVersion : 'not loaded'),

                  const SizedBox(height: Metrics.gap),
                  const _Vendor(),

                  const SizedBox(height: Metrics.pad),
                  const _Section('Danger'),
                  RxButton('Delete everything on this device',
                      weight: Weight.secondary,
                      icon: Icons.delete_outline,
                      wide: true,
                      onTap: () => _confirmWipe(context)),

                  // The note that used to sit here said nobody outside the
                  // project had reviewed the cryptography. That stopped being
                  // true in August 2026, when an external review found two
                  // defects and both were fixed with regression tests, so it
                  // was removed on 1 September 2026 as out of date rather than
                  // as inconvenient. What is still true is in `docs/` and in
                  // the threat model, which is where somebody weighing this
                  // seriously will look; a permanent warning on a settings
                  // screen is read by everybody else, who cannot act on it.
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

  /// Confirmed, because it clears the screen and looks like data loss.
  ///
  /// Nothing is deleted, but somebody watching their history vanish will not
  /// believe that unless they were told first.
  Future<void> _confirmGoDark(BuildContext context) async {
    final t = RotelyxThemeScope.of(context);

    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('Turn on ghost mode?',
            style: Type.title.copyWith(color: t.text)),
        content: Text(
          'From now until you quit, nothing is written to this phone. Your '
          'saved conversations are not deleted, but they come off the screen '
          'until you open the app again and enter your password.',
          style: Type.body.copyWith(color: t.muted),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child:
                  Text('Cancel', style: Type.label.copyWith(color: t.muted))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Turn it on',
                  style: Type.label.copyWith(color: Tone.accent))),
        ],
      ),
    );

    if (yes == true) {
      store.goDark();
      if (context.mounted) setState(() {});
    }
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
/// What `pubspec.yaml` said when this was built, as the store shows it.
///
/// `flutter build` puts both of these in `DART_DEFINES` for every platform, so
/// there is nothing to install and nothing to keep in step by hand: changing
/// the version in `pubspec.yaml` changes this.
const _buildName = String.fromEnvironment('FLUTTER_BUILD_NAME');
const _buildNumber = String.fromEnvironment('FLUTTER_BUILD_NUMBER');

/// A second source for the version, passed on the build command line.
///
/// Flutter is supposed to supply the two above on every `flutter build`, and on
/// this project it did not reach the binary: the screen read "development
/// build" on a release that had been installed from the store. A version
/// nobody can read is a bug report nobody can place, so there is a fallback
/// and it no longer claims to be anything.
const _appVersionDefine = String.fromEnvironment('APP_VERSION');

String get _appVersion {
  if (_buildName.isNotEmpty) {
    return _buildNumber.isEmpty ? _buildName : '$_buildName ($_buildNumber)';
  }
  if (_appVersionDefine.isNotEmpty) return _appVersionDefine;
  return 'unknown';
}

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
          const RxChip('internally audited'),
        ],
      ),
    );
  }
}

/// A section that starts closed.
///
/// # Why the protocol details are folded rather than removed
///
/// This application argues that hiding the cryptography is what every other
/// messenger does because their cryptography is the same as everyone else's.
/// That argument is only worth making if the details are actually here.
///
/// But they are not what somebody came to settings for. A person opening this
/// screen wants to turn notifications off, and meeting a key agreement they
/// have never heard of on the way is what makes an application feel like it
/// was built for somebody else. So they are one tap away rather than gone, and
/// the summary line says in ordinary words what the rows underneath say
/// precisely.
/// One of the two widget surfaces, and how much it may say.
///
/// The same three choices as the watch face, because it is the same question
/// asked about a different screen: nothing, a number, or a number and a name.
class _WidgetChoice extends StatelessWidget {
  const _WidgetChoice({
    required this.title,
    required this.value,
    required this.onPick,
    required this.t,
  });

  final String title;
  final FaceDetail value;
  final void Function(FaceDetail) onPick;
  final RotelyxTheme t;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Type.label.copyWith(color: t.text)),
        RadioGroup<FaceDetail>(
          groupValue: value,
          onChanged: (picked) {
            if (picked != null) onPick(picked);
          },
          child: Column(children: [
            for (final choice in FaceDetail.values)
              RadioListTile<FaceDetail>(
                value: choice,
                activeColor: Tone.accent,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  switch (choice) {
                    FaceDetail.nothing => 'Nothing',
                    FaceDetail.count => 'How many are waiting',
                    FaceDetail.name => 'How many, and who',
                  },
                  style: Type.body.copyWith(color: t.text),
                ),
              ),
          ]),
        ),
      ],
    );
  }
}

class _Fold extends StatefulWidget {
  const _Fold({required this.title, required this.summary, required this.children});

  final String title;
  final String summary;
  final List<Widget> children;

  @override
  State<_Fold> createState() => _FoldState();
}

class _FoldState extends State<_Fold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title,
                          style: Type.label.copyWith(color: t.text)),
                      const SizedBox(height: 2),
                      Text(widget.summary,
                          style: Type.small.copyWith(color: t.faint)),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: Motion.enter,
                  curve: Motion.enterCurve,
                  child: Icon(Icons.expand_more, size: 20, color: t.muted),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: Motion.sheet,
          curve: Motion.sheetCurve,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(top: Metrics.gap),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.children,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
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

/// Choosing which mailbox this device uses.
///
/// # Why this exists
///
/// If the mailbox can only ever be ours, then "we cannot see who you talk to"
/// is a promise somebody has to take on faith. If it can be theirs, it is a
/// property they can check. A messenger that will not let anybody host their
/// own is asking for exactly the trust it claims not to need.
class _MailboxPicker extends StatefulWidget {
  const _MailboxPicker({required this.onChanged});

  final VoidCallback onChanged;

  @override
  State<_MailboxPicker> createState() => _MailboxPickerState();
}

class _MailboxPickerState extends State<_MailboxPicker> {
  final _custom = TextEditingController();
  String? _problem;
  bool _adding = false;

  String get _current => store.mailboxChoice ?? defaultMailbox.url;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _use(String? url) {
    setState(() {
      store.mailboxChoice = url;
      _adding = false;
      _problem = null;
      _custom.clear();
    });
    widget.onChanged();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(url == null
          ? 'Back to ${defaultMailbox.name}'
          : 'Now using ${describeMailbox(url).title}'),
    ));
  }

  void _addCustom() {
    final problem = mailboxProblem(_custom.text);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    _use(_custom.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final current = _current;
    final custom = knownMailbox(current) == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in knownMailboxes)
          Padding(
            padding: const EdgeInsets.only(bottom: Metrics.gap),
            child: _MailboxRow(
              title: m.name,
              detail: m.host,
              chosen: !custom && m.url == current,
              onTap: () => _use(m.url == defaultMailbox.url ? null : m.url),
            ),
          ),

        if (custom)
          Padding(
            padding: const EdgeInsets.only(bottom: Metrics.gap),
            child: _MailboxRow(
              title: describeMailbox(current).title,
              detail: 'Yours',
              chosen: true,
              onTap: () {},
              onRemove: () => _use(null),
            ),
          ),

        if (_adding) ...[
          const SizedBox(height: 4),
          RxField(
            controller: _custom,
            hint: 'wss://your-server.example/mailbox',
            autofocus: true,
            onSubmit: (_) => _addCustom(),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
          ),
          if (_problem != null) ...[
            const SizedBox(height: Metrics.gap),
            RxNote(_problem!, tone: Tone.bad),
          ],
          const SizedBox(height: Metrics.gap),
          Row(children: [
            Expanded(
              child: RxButton('Use this one', wide: true, onTap: _addCustom),
            ),
            const SizedBox(width: Metrics.gap),
            Expanded(
              child: RxButton('Cancel',
                  weight: Weight.quiet,
                  wide: true,
                  onTap: () => setState(() {
                        _adding = false;
                        _problem = null;
                      })),
            ),
          ]),
        ] else
          RxButton('Use my own server',
              weight: Weight.secondary,
              icon: Icons.dns_outlined,
              wide: true,
              onTap: () => setState(() => _adding = true)),

        const SizedBox(height: Metrics.pad),
        RxNote(
          'A mailbox holds your messages until the other person collects them. '
          'It never sees what they say: everything is sealed before it gets '
          'there. What it does see is that this phone connected, from what '
          'address, and when. Run your own and that is nobody but you.',
          title: 'What a mailbox knows',
          tone: custom ? Tone.warn : null,
        ),
        if (custom) ...[
          const SizedBox(height: Metrics.gap),
          Text(
            'Conversations already started keep the mailbox they began on. '
            'This applies to the next one.',
            style: Type.small.copyWith(color: t.faint),
          ),
        ],
      ],
    );
  }
}

/// One mailbox in the list.
class _MailboxRow extends StatelessWidget {
  const _MailboxRow({
    required this.title,
    required this.detail,
    required this.chosen,
    required this.onTap,
    this.onRemove,
  });

  final String title;
  final String detail;
  final bool chosen;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: Motion.press,
        curve: Motion.pressCurve,
        padding: const EdgeInsets.all(Metrics.pad),
        decoration: BoxDecoration(
          color: chosen ? Tone.accent.withValues(alpha: 0.10) : t.raised,
          borderRadius: BorderRadius.circular(Metrics.radius),
          border: Border.all(color: chosen ? Tone.accent : t.line),
        ),
        child: Row(
          children: [
            Icon(chosen ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 19, color: chosen ? Tone.accent : t.faint),
            const SizedBox(width: Metrics.pad),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Type.label.copyWith(color: t.text)),
                  const SizedBox(height: 2),
                  Text(detail, style: Type.small.copyWith(color: t.faint)),
                ],
              ),
            ),
            if (onRemove != null)
              GestureDetector(
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(left: Metrics.gap),
                  child: Icon(Icons.close, size: 18, color: t.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
