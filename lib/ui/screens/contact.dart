/// What this device knows about the person on the other side.
///
/// # Why this screen had to exist before any of it was usable
///
/// `StoredConversation` has carried `nickname`, `picture`, `pinned`, `muted`
/// and `receipts` for a while, and until now **not one screen read any of
/// them**. The wire format could carry a picture, the store could keep a name,
/// and there was no way for a person to set either. That is not a feature half
/// built, it is a feature nobody can use, and it is worse than one that was
/// never started, because the backlog says it exists.
///
/// # Why a name here is a note and not a fact
///
/// This is the closest thing in this application to a contact record, and it is
/// the honest shape of one. There is no directory, so nothing verifies a label
/// and nothing can. What somebody calls themselves is a claim they made during
/// pairing; what you call them is a note you keep. The screen says so, and puts
/// the safety number beside it, because the safety number is the only thing
/// here that verifies a person.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/file_pick.dart';
import '../../rotelyx/export.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/rotelyx_store.dart';
import 'picture.dart' show shrinkToAvatar;
import '../theme.dart';
import '../widgets.dart';
import 'pin_set.dart';

class ContactSheet extends StatefulWidget {
  const ContactSheet({super.key, required this.conversationId, this.onChanged});

  final String conversationId;

  /// The list and the chat header both show what this changes.
  final VoidCallback? onChanged;

  /// Open it from the bottom, which is where a phone's thumb is.
  static Future<void> open(BuildContext context, String id,
      {VoidCallback? onChanged}) {
    final t = RotelyxThemeScope.of(context);
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.surface,
      isScrollControlled: true,
      // `isScrollControlled` lets this grow to the height of the screen, and
      // without this it grows *past* the status bar: on a phone with a clock
      // and a battery up there the first line of the sheet was drawn behind
      // them. The default is false because a sheet is usually short.
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => RotelyxThemeScope(
        theme: t,
        child: ContactSheet(conversationId: id, onChanged: onChanged),
      ),
    );
  }

  @override
  State<ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<ContactSheet> {
  StoredConversation? _conversation;
  late final TextEditingController _name;
  late final TextEditingController _groupName;
  bool _groupBusy = false;
  String? _groupProblem;

  @override
  void initState() {
    super.initState();
    final c = store.load(widget.conversationId);
    _conversation = c;
    _name = TextEditingController(text: c?.nickname ?? '');
    _groupName = TextEditingController(text: c?.groupName ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _groupName.dispose();
    super.dispose();
  }

  /// Whether this is a group, which is when a name and a picture of its own
  /// make sense. Read from the live session when this conversation is the
  /// live one, and from what the group has already been given otherwise.
  bool get _isGroup {
    final c = _conversation;
    if (c == null) return false;
    if (c.groupName.isNotEmpty || c.groupPicture != null) return true;
    return rotelyx.conversationId == c.id && rotelyx.memberCount > 2;
  }

  /// Name the group for everybody. Sent when the field is left, not on every
  /// keystroke: a name is one signal, not thirty.
  Future<void> _nameTheGroup() async {
    final name = _groupName.text.trim();
    final c = _conversation;
    if (c == null || name.isEmpty || name == c.groupName) return;
    if (rotelyx.conversationId != c.id) {
      setState(() => _groupProblem = 'Open the conversation first, so the others can be told.');
      return;
    }
    final sent = await rotelyx.setGroupIdentity(name: name);
    if (!mounted) return;
    setState(() {
      _conversation = store.load(c.id);
      _groupProblem = sent ? null : 'Could not tell the others yet. Try again when connected.';
    });
    widget.onChanged?.call();
  }

  Future<void> _pictureTheGroup() async {
    final c = _conversation;
    if (c == null) return;
    if (rotelyx.conversationId != c.id) {
      setState(() => _groupProblem = 'Open the conversation first, so the others can be told.');
      return;
    }
    setState(() {
      _groupBusy = true;
      _groupProblem = null;
    });
    try {
      final picked = await pickFile(maxBytes: 24 * 1024 * 1024, images: true);
      if (picked == null) return;
      final shrunk = await shrinkToAvatar(picked.bytes);
      if (shrunk == null) {
        setState(() => _groupProblem = 'That file is not an image this device can read.');
        return;
      }
      final sent = await rotelyx.setGroupIdentity(
          name: _groupName.text.trim(), picturePng: shrunk);
      if (!mounted) return;
      setState(() {
        _conversation = store.load(c.id);
        if (!sent) _groupProblem = 'Could not tell the others yet. Try again when connected.';
      });
      widget.onChanged?.call();
    } on NoFilePicker catch (e) {
      if (mounted) setState(() => _groupProblem = e.message);
    } on Object {
      if (mounted) setState(() => _groupProblem = 'That image could not be read.');
    } finally {
      if (mounted) setState(() => _groupBusy = false);
    }
  }

  /// Save, tell whoever is showing this conversation, and stay open.
  ///
  /// Every control on this sheet writes immediately. There is no Save button,
  /// because a sheet with one has a state where what is on screen is not what
  /// is stored, and a person who closes it then loses a change they watched
  /// themselves make.
  void _write(void Function(StoredConversation c) change) {
    final c = _conversation;
    if (c == null) return;
    setState(() => change(c));
    store.save(c);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final c = _conversation;

    if (c == null) {
      return const Padding(
        padding: EdgeInsets.all(Metrics.gap),
        child: RxNote('This conversation is no longer on this device.'),
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Metrics.gap,
          right: Metrics.gap,
          top: 18,
          bottom: MediaQuery.of(context).viewInsets.bottom + Metrics.gap,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A handle to drag, and a button to press.
              //
              // The handle alone was the whole way out, and inside a scrolling
              // sheet a downward drag scrolls rather than dismisses. On
              // Android the hardware gesture still closed it; on iOS there is
              // no such thing, so the sheet had no exit at all and the only
              // move left was to kill the application.
              Row(
                children: [
                  const SizedBox(width: 44),
                  Expanded(
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: t.line,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      tooltip: 'Close',
                      icon: Icon(Icons.close, size: 20, color: t.muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Metrics.gap),

              Row(
                children: [
                  // Their face, shown and not edited.
                  //
                  // This used to be a picker, and pressing it set your own
                  // picture into their card while announcing it to them as
                  // yours. A contact's face arrives from the contact; yours is
                  // in Settings. Nobody chooses a face for somebody else.
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: c.face == null
                        ? RxAvatar(c.displayTitle, size: 64)
                        : ClipOval(
                            child: Image.memory(c.face!,
                                width: 64, height: 64, fit: BoxFit.cover)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Type.title.copyWith(color: t.text)),
                        Text(
                          c.nickname.isEmpty
                              ? 'The name they chose'
                              : 'They call themselves ${c.title}',
                          style: Type.small.copyWith(color: t.faint),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: Metrics.gap),

              // A group gets a name and a face of its own, for everybody in
              // it. It used to be listed as "somebody and 9 others", which
              // is a description, not a name, and every group looked like
              // every other group.
              if (_isGroup) ...[
                const _Section('This group'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _groupName,
                        style: Type.body.copyWith(color: t.text),
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          hintText: 'A name for the group',
                          hintStyle: Type.body.copyWith(color: t.faint),
                          filled: true,
                          fillColor: t.raised,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Metrics.radius),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                        ),
                        onSubmitted: (_) => _nameTheGroup(),
                        onEditingComplete: _nameTheGroup,
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      tooltip: 'Choose a picture for the group',
                      onPressed: _groupBusy ? null : _pictureTheGroup,
                      icon: _groupBusy
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.add_photo_alternate_outlined,
                              color: t.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                RxNote(_groupProblem ??
                    'Everybody in the group sees the name and the picture. '
                    'Anybody in it can change them, and everybody sees who did.'),
                const SizedBox(height: Metrics.gap),
              ],

              const _Section('What you call them'),
              TextField(
                controller: _name,
                style: Type.body.copyWith(color: t.text),
                decoration: InputDecoration(
                  hintText: c.title,
                  hintStyle: Type.body.copyWith(color: t.faint),
                  filled: true,
                  fillColor: t.raised,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Metrics.radius),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  suffixIcon: _name.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Use the name they chose',
                          icon: Icon(Icons.backspace_outlined,
                              size: 17, color: t.muted),
                          onPressed: () {
                            _name.clear();
                            _write((c) => c.nickname = '');
                          },
                        ),
                ),
                onChanged: (value) => _write((c) => c.nickname = value.trim()),
              ),
              const SizedBox(height: 8),
              const RxNote(
                'Nothing verifies a name, here or anywhere else. What they call '
                'themselves is a claim they made when you paired. What you call '
                'them is a note you keep on this device. The safety number is '
                'the only thing that proves who you are talking to.',
              ),

              // The invitation, when this conversation has one.
              //
              // A meeting phrase used to be infinite and irrevocable: it never
              // expired, nobody counted who had walked through it, and the
              // only way to close it was to agree different words with
              // everybody already inside. These are the limits every
              // comparable application puts on an invitation, and the off
              // switch is what removing somebody actually needs, because
              // nothing identifies a person across conversations and anybody
              // refused by their key makes a new one in a second.
              if (c.meetingTag != null) ...[
                const SizedBox(height: Metrics.gap),
                const _Section('Who may still join'),

                _Toggle(
                  title: 'Let them in without asking',
                  subtitle: c.meetingNeedsApproval
                      ? 'Somebody has to say yes to each person'
                      : 'Anybody with the invitation walks straight in',
                  icon: Icons.how_to_reg_outlined,
                  value: !c.meetingNeedsApproval,
                  onChanged: (v) => _write((c) => c.meetingNeedsApproval = !v),
                ),

                Padding(
                  padding: const EdgeInsets.only(
                      left: Metrics.wide, right: Metrics.wide, bottom: 8),
                  child: Text(
                    c.meetingNeedsApproval
                        ? 'Right for an invitation that has been passed '
                            'around: it does not know who it was given to.'
                        : 'Right for one you handed to a person: the decision '
                            'was made when you handed it over.',
                    style: Type.small.copyWith(color: t.faint),
                  ),
                ),

                if (c.meetingMaxUses != null || c.meetingUses > 0)
                  Padding(
                    padding: const EdgeInsets.only(
                        left: Metrics.wide, right: Metrics.wide, bottom: 8),
                    child: Text(
                      c.meetingMaxUses == null
                          ? 'Used ${c.meetingUses} times so far'
                          : 'Used ${c.meetingUses} of ${c.meetingMaxUses}',
                      style: Type.small.copyWith(color: t.muted),
                    ),
                  ),

                if (!c.meetingIsOpen) ...[
                  Padding(
                    padding: const EdgeInsets.only(
                        left: Metrics.wide, right: Metrics.wide, bottom: 4),
                    child: Text(
                      'Closed: ${c.meetingClosedBecause}',
                      style: Type.small.copyWith(color: t.text),
                    ),
                  ),
                  // Deliberately not a "reset" button.
                  //
                  // Putting the count back to zero would reopen the door to
                  // everybody who already had the words, which is the thing
                  // these limits exist to stop. An invitation is replaced, not
                  // refilled, and a phrase cannot be replaced without changing
                  // the words, because the address is made out of them. Saying
                  // so costs a sentence; a button that appeared to reset it and
                  // left the same door open would cost somebody their group.
                  Padding(
                    padding: const EdgeInsets.only(
                        left: Metrics.wide, right: Metrics.wide, bottom: 8),
                    child: Text(
                      'To let somebody else in, invite them again. That makes a '
                      'new invitation and this one stays closed. Re-opening '
                      'this one would let back in everybody who already had it.',
                      style: Type.small.copyWith(color: t.faint),
                    ),
                  ),
                ],

                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Metrics.wide - 8),
                    child: TextButton.icon(
                      onPressed: c.meetingTag == null
                          ? null
                          : () => _write((c) => c.meetingTag = null),
                      icon: Icon(Icons.link_off, size: 16, color: t.muted),
                      label: Text('Turn the invitation off',
                          style: Type.small.copyWith(color: t.muted)),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: Metrics.gap),
              const _Section('On this device'),

              _Toggle(
                title: 'Pin to the top',
                subtitle: 'Keeps it above the rest of the list',
                icon: Icons.push_pin_outlined,
                value: c.pinned,
                onChanged: (v) => _write((c) => c.pinned = v),
              ),
              _Toggle(
                title: 'Mute',
                subtitle: c.muted
                    ? 'No sound and no vibration. It still appears'
                    : 'Sound and vibration when something arrives',
                icon: Icons.notifications_off_outlined,
                value: c.muted,
                onChanged: (v) => _write((c) => c.muted = v),
              ),
              _Toggle(
                title: 'Tell them when you have read a message',
                subtitle: c.receipts
                    ? 'Costs one extra message each time you open this'
                    : 'Off. They see delivered, never read',
                icon: Icons.done_all,
                value: c.receipts,
                onChanged: (v) => _write((c) => c.receipts = v),
              ),
              const SizedBox(height: 6),
              const RxNote(
                'Telling them you read it means sending them something, '
                'because there is no back channel here and there should not be '
                'one. So whoever runs the server sees a message go out every '
                'time you open this conversation. They still cannot read a '
                'word of it, but they can tell when you looked. That is why '
                'this is off unless you turn it on.',
                title: 'What a read receipt costs'
              ),

              const SizedBox(height: Metrics.gap),
              const _Section('Lock this conversation'),
              _Toggle(
                title: 'Ask for a PIN to open it',
                subtitle: store.isLocked(c.id)
                    ? 'Sealed under that PIN as well as your password'
                    : 'Off. It opens with the rest of your history',
                icon: Icons.lock_outline,
                value: store.isLocked(c.id),
                onChanged: (want) async {
                  if (!want) {
                    store.unlockChat(c.id);
                    if (mounted) setState(() {});
                    widget.onChanged?.call();
                    return;
                  }
                  final pin = await SetPinSheet.ask(context);
                  if (pin == null) return;
                  store.lockChat(c.id, pin);
                  if (mounted) setState(() {});
                  widget.onChanged?.call();
                },
              ),
              const SizedBox(height: 6),
              const RxNote(
                'This one seals rather than hides. The conversation is '
                'encrypted under its PIN as well as your password, so it '
                'stays unreadable even to this application with your vault '
                'open. Forgetting the PIN loses this conversation and nothing '
                'else, and nothing here can recover it.\n\n'
                'What stays visible is that the conversation exists and who it '
                'is with. Hiding that would mean hiding the row, and then '
                'nobody could find it to unlock.',
                title: 'What this locks and what it does not',
              ),

              const SizedBox(height: Metrics.gap),
              const _Section('Export'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.description_outlined, size: 20, color: t.muted),
                title: Text('Copy this conversation as text',
                    style: Type.body.copyWith(color: t.text)),
                subtitle: Text(
                    'Goes to the clipboard, unencrypted',
                    style: Type.small.copyWith(color: t.faint)),
                onTap: () {
                  Clipboard.setData(
                      ClipboardData(text: exportConversation(c)));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text(
                            'Copied. It is not encrypted: paste it somewhere '
                            'you would keep the conversation itself.')),
                  );
                },
              ),

              const SizedBox(height: Metrics.gap),
              _Danger(
                label: 'Delete this conversation',
                detail: 'Removes every message and the session. It cannot be '
                    'undone and it does not touch their copy.',
                onConfirm: () {
                  store.remove(widget.conversationId);
                  widget.onChanged?.call();
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(label.toUpperCase(),
          style: Type.small.copyWith(
              color: t.faint, letterSpacing: 1.1, fontWeight: FontWeight.w700)),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeColor: Tone.accent,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, size: 20, color: value ? Tone.accent : t.muted),
      title: Text(title, style: Type.body.copyWith(color: t.text)),
      subtitle: Text(subtitle, style: Type.small.copyWith(color: t.faint)),
    );
  }
}

/// Something irreversible, behind a confirmation.
class _Danger extends StatefulWidget {
  const _Danger({
    required this.label,
    required this.detail,
    required this.onConfirm,
  });

  final String label;
  final String detail;
  final VoidCallback onConfirm;

  @override
  State<_Danger> createState() => _DangerState();
}

class _DangerState extends State<_Danger> {
  bool _asking = false;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    const red = Color(0xFFE0574A);

    if (!_asking) {
      return TextButton.icon(
        onPressed: () => setState(() => _asking = true),
        icon: const Icon(Icons.delete_outline, size: 18, color: red),
        label: Text(widget.label, style: Type.body.copyWith(color: red)),
        style: TextButton.styleFrom(padding: EdgeInsets.zero),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.detail, style: Type.small.copyWith(color: t.muted)),
        const SizedBox(height: 10),
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() => _asking = false),
              child: Text('Keep it', style: Type.body.copyWith(color: t.muted)),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: widget.onConfirm,
              style: FilledButton.styleFrom(backgroundColor: red),
              child: const Text('Delete'),
            ),
          ],
        ),
      ],
    );
  }
}
