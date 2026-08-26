/// Starting a conversation with somebody who is not in any directory.
///
/// # The problem this screen solves
///
/// Every other messenger starts a conversation by looking somebody up. You have
/// their number, or their username, and a server maps it to them. That server
/// therefore knows who talks to whom, which is the single most revealing thing
/// about a conversation and the one piece of metadata encryption does not hide.
///
/// Rotelyx has no such server. There is nothing to look up, so a conversation
/// cannot begin by finding a person. It begins by two people arriving at the
/// same place.
///
/// # The place
///
/// A *meeting place* is one address at the mailbox, derived from a shared
/// string. Both sides derive the same address from the same string, arrive
/// there, and exchange keys. The mailbox sees two parties meet at an address it
/// cannot connect to either of them.
///
/// Three ways to agree on the string, differing only in how it travels:
///
///   **A QR code.** One side shows, the other scans. The string is 120 random
///   bits, so it cannot be guessed. This is the one to use when the two people
///   are in the same room.
///
///   **A phrase.** Both sides type the same words. Convenient over a phone
///   call, and weaker: a phrase a person invents can be guessed by somebody who
///   knows them.
///
///   **An invitation.** A long block of text carrying the keys directly, for
///   sending through some other application. Too large for a QR, which is why
///   the QR uses a meeting code instead.
///
/// # What none of them do
///
/// None of them prove who is at the other end. Whoever reaches the meeting
/// place first completes the handshake, intended person or not. That is not a
/// flaw to be patched; it is what it means to have no authority vouching for
/// identities.
///
/// The safety number is the check, and it is the first thing the conversation
/// screen shows.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rotelyx/meeting_code.dart';
import '../../platform/share.dart';
import '../../rotelyx/invite_link.dart';
import '../../rotelyx/mailboxes.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../../rotelyx/rotelyx_wasm.dart';
import '../brand.dart';
import '../theme.dart';
import '../widgets.dart';
import 'scan.dart';

class PairScreen extends StatefulWidget {
  const PairScreen({
    super.key,
    required this.onDone,
    required this.onCancel,
    this.arriving,
  });

  final ValueChanged<String> onDone;
  final VoidCallback onCancel;

  /// An invitation this screen was opened by, rather than one typed into it.
  ///
  /// Filled in and shown on the tab it belongs to, but not accepted on its own:
  /// the name field above it is still blank, and accepting before somebody has
  /// said who they are would introduce them as "anon" with no way to correct
  /// it afterwards.
  final String? arriving;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  /// Screenshot fixtures, resolved at compile time so no release build carries
  /// them. The same trick `lib/ui/app.dart` uses for the other surfaces:
  ///
  ///   flutter build web --dart-define=screen=pair --dart-define=showQr=true
  ///
  /// The point is to capture a screen that otherwise only exists after a
  /// network round trip, without faking the network.
  static const _fixtureQr = bool.fromEnvironment('showQr');
  static const _fixtureScan = bool.fromEnvironment('showScan');

  final _name = TextEditingController();
  final _phrase = TextEditingController();
  final _code = TextEditingController();

  int _tab = 0;
  bool _busy = false;
  String? _error;

  /// The invitation blob, when this device produced one.
  String? _invitation;

  /// The meeting code being shown as a QR, when this device is the one showing.
  String? _meeting;

  /// The mailbox the pasted invitation names, or null.
  ///
  /// Null covers three cases that all mean the same thing to this screen: the
  /// field is empty, what is in it is not an invitation yet, or it is one from
  /// a build made before invitations carried a mailbox. None of them is worth
  /// telling anybody about while they are still typing.
  String? get _arrivingMailbox {
    final code = codeFromLink(_code.text);
    if (code == null || code.isEmpty) return null;
    return mailboxFromCode(code);
  }

  PairingRole? _role;

  /// How long a new invitation will be good for.
  ///
  /// An hour by default, which is what one person sending one to another
  /// person needs. Longer exists for a group: somebody opening a conversation
  /// that people join over a week cannot hand out an invitation that dies at
  /// lunchtime.
  Duration _invitationLife = RotelyxService.invitationLifetime;



  @override
  void initState() {
    super.initState();
    _name.text = store.load('me')?.title ?? '';

    // Opened by a link rather than by the button. Fill the field and show the
    // tab it belongs to; accepting is still the person's to do, because the
    // name above it is blank and going ahead now introduces them as "anon".
    final arriving = widget.arriving;
    if (arriving != null && arriving.isNotEmpty) {
      _code.text = arriving;
      _tab = 2;
    }

    if (_fixtureQr) _meeting = newMeetingCode();
    if (_fixtureScan) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => ScanScreen.open(context));
    }

    rotelyx.stateChanges.listen((s) {
      if (!mounted) return;
      if (s == RotelyxState.joined) {
        _persist();
      } else if (s == RotelyxState.failed) {
        setState(() {
          _busy = false;
          _meeting = null;
          _error = rotelyx.lastError;
        });
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _phrase.dispose();
    _code.dispose();
    super.dispose();
  }

  /// The record this pairing created, so it is created once.
  ///
  /// `joined` is not a moment, it is a state, and the stream says so more than
  /// once: again when the post-quantum commit lands, again on every membership
  /// change, again whenever delivery moves. Without this guard each of those
  /// made another conversation with another id, the newest one took the
  /// messages, and the ones before it sat in the list empty forever. One scan
  /// produced two entries, which is exactly what it looked like.
  String? _persisted;

  /// Create the conversation record the moment the group exists, so a crash a
  /// second later still leaves something to reopen.
  void _persist() {
    if (_persisted != null) return;

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    _persisted = id;

    // The other side's name, which the handshake carried and nothing was
    // reading. This used to be the meeting phrase, which is wrong twice over: a
    // QR pairing has no phrase, so those conversations were all called
    // "Conversation", and a phrase is closer to a secret than to a title.
    final title = rotelyx.conversationName ?? 'Conversation';

    store.save(StoredConversation(
      id: id,
      title: title,
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));
    rotelyx.persistTo(id);
    widget.onDone(id);
  }

  Future<void> _attempt(Future<void> Function() run, {PairingRole? role}) async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Choose a name others will see.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _role = role;
    });

    try {
      await RotelyxWasm.whenReady();
      await run();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _meeting = null;
          _error = '$e';
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // The QR path
  // ---------------------------------------------------------------------------

  /// Mint a code, start waiting at the place it names, and put it on screen.
  ///
  /// The waiting starts before the code is shown, not after. A code displayed
  /// while nothing is listening is a code somebody can scan into a silence.
  Future<void> _showCode() async {
    final code = newMeetingCode();
    await _attempt(
      () async {
        await rotelyx.pairByMeetingCode(
          code: code,
          displayName: _name.text.trim(),
          role: PairingRole.host,
        );
        if (mounted) setState(() => _meeting = code);
      },
      role: PairingRole.host,
    );
  }

  Future<void> _scanCode() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Choose a name others will see.');
      return;
    }

    // What the camera is for, before the system asks. The system prompt says
    // "Allow Rotelyx to take pictures" and nothing else, which is not the
    // question a person is actually being asked here.
    final ready = await explainPermission(
      context,
      icon: Icons.photo_camera_outlined,
      title: 'Point the camera at their code',
      body: 'The camera is used to read the code on their screen and nothing '
          'else. No photograph is taken or kept, and nothing leaves this '
          'phone: the picture is looked at for a code and thrown away.\n\n'
          'If you would rather not, the other two ways of starting a '
          'conversation need no camera.',
      allow: 'Open the camera',
    );
    if (!ready || !mounted) return;

    final code = await ScanScreen.open(context);
    if (code == null || !mounted) return;

    await _attempt(
      () => rotelyx.pairByMeetingCode(
        code: code,
        displayName: _name.text.trim(),
        role: PairingRole.guest,
      ),
      role: PairingRole.guest,
    );
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    // Waiting takes over the screen except when there is a code to show, since
    // showing the code *is* what waiting looks like on that path.
    final waiting = _busy && _invitation == null && _meeting == null;

    return Container(
      color: t.backdrop,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Metrics.wide),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: widget.onCancel,
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.close, size: 20, color: t.muted),
                    ),
                  ),
                  const SizedBox(height: Metrics.gap),
                  Text('New conversation',
                      style: Type.display.copyWith(color: t.text)),
                  const SizedBox(height: 6),
                  Text(
                    'Nobody can be looked up here, so the two of you agree '
                    'on where to meet first. Which way is easiest depends on '
                    'where the other person is right now.',
                    style: Type.body.copyWith(color: t.muted),
                  ),
                  const SizedBox(height: Metrics.wide),

                  if (waiting)
                    _Waiting(
                        role: _role,
                        onCancel: () => setState(() {
                              _busy = false;
                              _role = null;
                            }))
                  else ...[
                    RxField(
                      controller: _name,
                      label: 'Your name',
                      hint: 'Anything you like',
                      help: 'Only a label, and anyone can pick any of them. It '
                          'is not how you know who you are talking to.',
                    ),
                    const SizedBox(height: Metrics.pad),
                    _Tabs(
                      index: _tab,
                      // Named for where the other person is, because that is
                      // the thing the user already knows and the mechanism is
                      // the thing they are trying to work out.
                      labels: const ['Together', 'On a call', 'By message'],
                      onTap: (i) => setState(() => _tab = i),
                    ),
                    const SizedBox(height: Metrics.pad),
                    switch (_tab) {
                      0 => _qrMode(t),
                      1 => _phraseMode(t),
                      _ => _codeMode(t),
                    },
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: Metrics.pad),
                    RxNote(_error!, tone: Tone.bad, title: 'Did not work'),
                  ],

                  const SizedBox(height: Metrics.wide),
                  const RxNote(
                    'This is a pre-release build and nobody outside the '
                    'project has audited it yet. The cryptography is public and '
                    'the code is there to read.',
                    title: 'Before you rely on this',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _qrMode(RotelyxTheme t) {
    final code = _meeting;

    if (code != null) {
      return Column(children: [
        Center(child: RxQrCode(code)),
        const SizedBox(height: Metrics.pad),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Tone.accent)),
          const SizedBox(width: Metrics.gap),
          Text('Waiting for them to point a camera at it',
              style: Type.label.copyWith(color: t.text)),
        ]),
        const SizedBox(height: Metrics.pad),
        SelectableText(
          prettyMeetingCode(code),
          textAlign: TextAlign.center,
          style: Type.numeric.copyWith(color: t.muted, letterSpacing: 1.2),
        ),
        const SizedBox(height: 6),
        Text('No camera? Read these words out to them instead.',
            textAlign: TextAlign.center,
            style: Type.small.copyWith(color: t.faint)),
        const SizedBox(height: Metrics.pad),
        Row(children: [
          Expanded(
            child: RxButton('Copy',
                weight: Weight.secondary,
                icon: Icons.copy,
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Meeting code copied')));
                  }
                }),
          ),
          const SizedBox(width: Metrics.gap),
          Expanded(
            child: RxButton('Cancel',
                weight: Weight.quiet,
                onTap: () => setState(() {
                      _meeting = null;
                      _busy = false;
                      _role = null;
                    })),
          ),
        ]),
        const SizedBox(height: Metrics.pad),
        const RxNote(
          'Anyone who can see this screen could get there before your contact '
          'does, and you would end up connected to them instead. Show it to '
          'one person, and once you are connected read the safety number to '
          'each other: if it matches, nobody got in between.',
          tone: Tone.warn,
          title: 'While this is on screen',
        ),
      ]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RxButton('Show my code',
            icon: Icons.qr_code_2, wide: true, onTap: _showCode),
        const SizedBox(height: Metrics.gap),
        RxButton('Scan their code',
            weight: Weight.secondary,
            icon: Icons.photo_camera_outlined,
            wide: true,
            onTap: _scanCode),
        const SizedBox(height: Metrics.pad),
        const RxNote(
          'One of you shows the code and the other points a camera at it. It '
          'does not matter which way round. The code is only a place to meet, '
          'not a key, and it stops meaning anything the moment you are '
          'connected.',
          title: 'When you are in the same room',
        ),
      ],
    );
  }

  Widget _phraseMode(RotelyxTheme t) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RxField(
            controller: _phrase,
            label: 'A phrase you both type',
            hint: 'At least 8 characters',
            help: 'Say it out loud on the call, then you both type it here. '
                'Whoever types it first is who you end up talking to, so do '
                'not use one somebody could guess, and do not send it in a '
                'message.',
          ),
          const SizedBox(height: Metrics.pad),
          Row(children: [
            Expanded(
              child: RxButton('Wait here',
                  onTap: () => _attempt(
                      () => rotelyx.pairByPhrase(
                            phrase: _phrase.text,
                            displayName: _name.text.trim(),
                            role: PairingRole.host,
                          ),
                      role: PairingRole.host)),
            ),
            const SizedBox(width: Metrics.gap),
            Expanded(
              child: RxButton('Join',
                  weight: Weight.secondary,
                  onTap: () => _attempt(
                      () => rotelyx.pairByPhrase(
                            phrase: _phrase.text,
                            displayName: _name.text.trim(),
                            role: PairingRole.guest,
                          ),
                      role: PairingRole.guest)),
            ),
          ]),
          const SizedBox(height: 6),
          Center(
            child: Text('One side waits, the other joins.',
                style: Type.small.copyWith(color: t.faint)),
          ),
        ],
      );

  Widget _codeMode(RotelyxTheme t) {
    final code = _invitation;
    if (code != null) {
      return Column(children: [
        Container(
          padding: const EdgeInsets.all(Metrics.pad),
          decoration: BoxDecoration(
            color: t.raised,
            borderRadius: BorderRadius.circular(Metrics.radius),
            border: Border.all(color: t.line),
          ),
          child: Text(
            '${code.substring(0, 64)}...',
            style: Type.small.copyWith(color: t.faint, fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: Metrics.pad),
        Text('Waiting for them to open it',
            style: Type.label.copyWith(color: t.text)),
        const SizedBox(height: 4),
        Text(
            () {
              final at = expiryOfCode(code);
              if (at == null) {
                return 'This one has no time limit. Whoever opens it first '
                    'becomes the other side of the conversation.';
              }
              final left = at.difference(DateTime.now());
              final when = left.inHours >= 24
                  ? '${left.inDays} day${left.inDays == 1 ? '' : 's'}'
                  : left.inHours >= 1
                      ? '${left.inHours} hour${left.inHours == 1 ? '' : 's'}'
                      : '${left.inMinutes} minutes';
              return 'Good for $when. Whoever opens it first becomes the '
                  'other side of the conversation.';
            }(),
            textAlign: TextAlign.center,
            style: Type.small.copyWith(color: t.faint)),
        const SizedBox(height: Metrics.pad),
        RxButton('Send invitation',
            icon: Icons.ios_share,
            wide: true,
            onTap: () async {
              final link = inviteLink(code);
              final shared = await shareText(link,
                  title: 'Invite someone to Rotelyx',
                  subject: 'A private conversation');
              if (shared || !mounted) return;

              await Clipboard.setData(ClipboardData(text: link));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')));
              }
            }),
        const SizedBox(height: Metrics.gap),
        RxButton('Copy the link',
            weight: Weight.secondary,
            icon: Icons.link,
            wide: true,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: inviteLink(code)));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')));
              }
            }),
      ]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Good for', style: Type.small.copyWith(color: t.faint)),
        const SizedBox(height: Metrics.gap),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (life, label) in const [
              (Duration(hours: 1), '1 hour'),
              (Duration(hours: 24), '1 day'),
              (Duration(days: 7), '1 week'),
              (Duration.zero, 'No limit'),
            ])
              GestureDetector(
                onTap: () => setState(() => _invitationLife = life),
                child: AnimatedContainer(
                  duration: Motion.press,
                  curve: Motion.pressCurve,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: life == _invitationLife ? Tone.accent : t.raised,
                    borderRadius: BorderRadius.circular(Metrics.pill),
                    border: Border.all(
                        color: life == _invitationLife
                            ? Tone.accent
                            : t.line),
                  ),
                  child: Text(label,
                      style: Type.small.copyWith(
                          color: life == _invitationLife
                              ? Colors.white
                              : t.muted,
                          fontWeight: FontWeight.w700)),
                ),
              ),
          ],
        ),
        if (_invitationLife == Duration.zero) ...[
          const SizedBox(height: Metrics.gap),
          const RxNote(
            'An invitation carries the keys themselves, so one with no limit '
            'is a key sitting in whatever you sent it through. Anybody who '
            'finds it later can still use it. Worth it for a group people join '
            'over weeks, and not worth it for one person.',
            tone: Tone.warn,
          ),
        ],
        const SizedBox(height: Metrics.pad),
        RxButton('Create an invitation',
            icon: Icons.mail_outline,
            wide: true,
            onTap: () => _attempt(() async {
                  final c = await rotelyx.createInvitation(
                    displayName: _name.text.trim(),
                    validFor: _invitationLife,
                  );
                  if (mounted) setState(() => _invitation = c);
                })),
        const SizedBox(height: Metrics.pad),
        Row(children: [
          Expanded(child: Divider(color: t.line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('or paste one',
                style: Type.small.copyWith(color: t.faint)),
          ),
          Expanded(child: Divider(color: t.line)),
        ]),
        const SizedBox(height: Metrics.pad),
        RxField(
            controller: _code,
            hint: 'Paste the link they sent you',
            lines: 3,
            onChanged: (_) => setState(() {}),
          ),
          if (_arrivingMailbox != null) ...[
            const SizedBox(height: Metrics.gap),
            _MailboxNotice(url: _arrivingMailbox!),
          ],
        const SizedBox(height: Metrics.gap),
        RxButton('Accept invitation',
            weight: Weight.secondary,
            wide: true,
            onTap: () => _attempt(() async {
                  // A link or a bare code. People paste what they were given.
                  final code = codeFromLink(_code.text);
                  if (code == null || code.isEmpty) {
                    throw const FormatException(
                        'that invitation could not be opened. It may have been '
                        'used already, or expired.');
                  }
                  return rotelyx.acceptInvitation(
                    code: code,
                    displayName: _name.text.trim(),
                  );
                })),
        const SizedBox(height: Metrics.pad),
        const RxNote(
          'Use this when you cannot be together and cannot speak. The link '
          'carries the keys themselves rather than a place to meet, which is '
          'why it works with nothing arranged beforehand. The part after the '
          'hash is never sent to any server, including ours: it travels only '
          'inside the message you send.',
          title: 'When you can only send a message',
        ),
      ],
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.index, required this.labels, required this.onTap});

  final int index;
  final List<String> labels;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(Metrics.radius),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onTap(i),
                child: Container(
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == index ? Tone.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(Metrics.radius - 4),
                  ),
                  child: Text(labels[i],
                      style: Type.label.copyWith(
                          color: i == index ? Colors.white : t.muted)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.role, required this.onCancel});

  final PairingRole? role;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    final text = switch (role) {
      PairingRole.host =>
        'Waiting. Have the other person type the same phrase.',
      PairingRole.guest => 'Knocking. Waiting for them to answer.',
      _ => 'Loading',
    };

    return Column(children: [
      const SizedBox(height: Metrics.wide),
      const SizedBox(
          width: 26,
          height: 26,
          child:
              CircularProgressIndicator(strokeWidth: 2.5, color: Tone.accent)),
      const SizedBox(height: Metrics.pad),
      Text(text,
          textAlign: TextAlign.center,
          style: Type.body.copyWith(color: t.muted)),
      const SizedBox(height: Metrics.pad),
      RxButton('Cancel', weight: Weight.quiet, onTap: onCancel),
      const SizedBox(height: Metrics.wide),
    ]);
  }
}

/// Where an invitation is about to take you.
///
/// # Why this is on screen at all
///
/// An invitation carries the mailbox it was made on, and anybody can run one.
/// So an invitation can send you to a host its sender chose. It cannot read a
/// word of what you say, everything is sealed before it gets there, but it sees
/// your address and when you connect.
///
/// Refusing unfamiliar ones would end self hosting, which is the argument this
/// application is built on. Saying nothing would make it a silent risk. So it
/// is named, before the button rather than after it, and marked when it is not
/// one of ours.
class _MailboxNotice extends StatelessWidget {
  const _MailboxNotice({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final described = describeMailbox(url);

    return RxNote(
      '${described.title}\n${described.detail}',
      title: described.familiar
          ? 'Connects through'
          : 'Connects through a mailbox you do not know',
      tone: described.familiar ? null : Tone.warn,
    );
  }
}
