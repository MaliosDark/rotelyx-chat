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

import '../../rotelyx/export.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'picture.dart';
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

  @override
  void initState() {
    super.initState();
    final c = store.load(widget.conversationId);
    _conversation = c;
    _name = TextEditingController(text: c?.nickname ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
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
          top: Metrics.pad,
          bottom: MediaQuery.of(context).viewInsets.bottom + Metrics.gap,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: Metrics.gap),

              Row(
                children: [
                  PicturePicker(
                    conversation: c,
                    onPicked: (bytes) => _write((c) => c.picture = bytes),
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
                    ? 'One extra envelope per conversation you open'
                    : 'Off. They see delivered, never read',
                icon: Icons.done_all,
                value: c.receipts,
                onChanged: (v) => _write((c) => c.receipts = v),
              ),
              const SizedBox(height: 6),
              const RxNote(
                'A read receipt is a message, because there is no side channel '
                'and there should not be one. That means the operator counts an '
                'envelope every time you open this conversation, and can see '
                'when you read even though not what. It is off by default for '
                'that reason and not because it is hard.',
                title: 'What a receipt costs',
              ),

              const SizedBox(height: Metrics.gap),
              const _Section('Lock this conversation'),
              _Toggle(
                title: 'Ask for a PIN to open it',
                subtitle: store.isLocked(c.id)
                    ? 'Sealed under that PIN as well as your passphrase'
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
                'encrypted under its PIN as well as your passphrase, so it '
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
