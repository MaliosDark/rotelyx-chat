/// One conversation.
///
/// The safety number sits at the top rather than behind a menu. It is the only
/// thing that detects the failure pairing cannot prevent, someone who learned
/// the phrase early and answered in the intended party's place, and a check
/// hidden behind two taps is a check nobody performs.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/file_pick.dart';

import '../../rotelyx/alerts.dart';
import '../../rotelyx/attachment.dart';

import '../../rotelyx/ephemeral.dart';
import '../../rotelyx/quoted.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../burn.dart';
import '../gestures.dart';
import 'contact.dart';
import '../theme.dart';
import '../widgets.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversationId,
    this.onBack,
    this.onChanged,
  });

  final String conversationId;
  final VoidCallback? onBack;
  final VoidCallback? onChanged;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  StoredConversation? _conversation;
  bool _showSafety = false;

  /// The message the composer is answering, if any.
  StoredMessage? _replyingTo;

  /// How long a message sent now should survive after it is read.
  ///
  /// Null is the ordinary case: messages stay. This is per composition rather
  /// than per conversation, so setting it once does not silently apply to
  /// everything said afterwards.
  int? _burnSeconds;

  /// Messages currently on fire, by their timestamp.
  ///
  /// Held here rather than on the message because a burn is a thing happening
  /// on this screen, not a fact about the conversation. Closing the screen
  /// mid-burn still removes the message: the deadline is what decides, and it
  /// is stored.
  final _burning = <DateTime>{};

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _conversation = store.load(widget.conversationId);
    // While this is on screen, a message in this conversation is not news.
    alerts.openConversation = widget.conversationId;
    alerts.read(widget.conversationId);
    _markRead();
    _startBurnClocks();

    // One timer for the screen rather than one per message. A conversation with
    // forty expiring messages should not hold forty timers.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _sweep());
    rotelyx.messages.listen(_onIncoming);
    // A delivery acknowledgement arrives as a state change, and the service
    // rewrites the stored message when it does, so this re-reads rather than
    // merely repainting.
    rotelyx.stateChanges.listen((_) {
      if (!mounted) return;
      setState(() => _conversation = store.load(widget.conversationId));
    });
    _resumeIfNeeded();
  }

  @override
  void dispose() {
    if (alerts.openConversation == widget.conversationId) {
      alerts.openConversation = null;
    }
    _tick?.cancel();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Reopen the MLS session for this conversation when it is not the live one.
  Future<void> _resumeIfNeeded() async {
    if (rotelyx.state == RotelyxState.joined) return;
    if (store.sessionBlob(widget.conversationId) == null) return;

    setState(() => _resuming = true);
    await rotelyx.resume(widget.conversationId);
    if (mounted) setState(() => _resuming = false);
  }

  bool _resuming = false;

  /// Re-read rather than append.
  ///
  /// `RotelyxService` writes every message down as it happens, including while
  /// this screen does not exist. Appending here as well would show each message
  /// twice; reading back is also the only way this screen sees what arrived
  /// before it was opened.
  void _onIncoming(RotelyxMessage _) {
    if (!mounted) return;
    setState(() => _conversation = store.load(widget.conversationId));
    // After the reload, not before. The service is what writes a message down,
    // so at the moment `send` returns this screen still holds the conversation
    // as it was, and starting clocks on that copy started none: the message
    // whose clock needed starting was not in it yet.
    _startBurnClocks();
    // Arriving while the conversation is open counts as read, or the badge
    // appears on a conversation the user is looking at.
    _markRead();
    widget.onChanged?.call();
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  Future<void> _pickFile() async {
    final PickedFile? file;
    try {
      file = await pickFile(maxBytes: maxAttachmentBytes);
    } on NoFilePicker catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${e.message}. The mailbox pads envelopes to a fixed '
              'ladder and the largest is 8 MB, so anything over 5 MB is refused '
              'before it is sealed.')));
      return;
    }

    // Null means the picker was closed without choosing, which is not a failure
    // and is not worth a message.
    if (file == null) return;

    final attachment =
        Attachment(name: file.name, mime: file.mime, bytes: file.bytes);

    if (rotelyx.state != RotelyxState.joined) return;
    rotelyx.send(attachment.encode());
  }

  /// Bring someone else in.
  ///
  /// The host stayed subscribed to the meeting place after pairing precisely so
  /// a later arrival has somewhere to knock, so adding a member is a matter of
  /// telling the user the phrase still works rather than of new machinery.
  void _addMember() {
    final t = RotelyxThemeScope.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Metrics.radius)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(Metrics.wide),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add someone', style: Type.title.copyWith(color: t.text)),
            const SizedBox(height: Metrics.gap),
            Text(
              'Give them the same meeting phrase. This conversation is still '
              'listening there, and whoever knocks next is admitted and '
              'brought up to the current epoch.',
              style: Type.body.copyWith(color: t.muted),
            ),
            const SizedBox(height: Metrics.pad),
            const RxNote(
              'Everyone already here re-derives their keys when a member joins, '
              'so the newcomer cannot read anything said before they arrived.',
              title: 'What they will and will not see',
            ),
            const SizedBox(height: Metrics.pad),
            RxButton('Close',
                weight: Weight.secondary,
                wide: true,
                onTap: () => Navigator.pop(context)),
          ],
        ),
      ),
    );
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;

    if (rotelyx.state != RotelyxState.joined) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This conversation is not connected.')));
      return;
    }

    final answering = _replyingTo;
    final body = answering == null
        ? text
        : Quoted(
            // Their label, or ours when answering ourselves, so the quote reads
            // the same on both devices.
            author: answering.mine
                ? rotelyx.displayName
                : (answering.author.isEmpty
                    ? _conversation?.title ?? ''
                    : answering.author),
            excerpt: Quoted.plain(answering.text),
            reply: text,
          ).encode();

    // The timer wraps everything else, so a reply or a file can expire too.
    final seconds = _burnSeconds;
    final wrapped = seconds == null
        ? body
        : Ephemeral.wrap(seconds: seconds, body: body).encode();

    if (rotelyx.send(wrapped)) {
      _input.clear();
      setState(() => _replyingTo = null);
      // No clock is started here. Our copy waits for them to read it, which is
      // what makes both countdowns run from the same moment.
    }
  }

  /// Reading a message is what starts its clock, on both devices.
  ///
  /// Only what they sent us is started here. Our own expiring messages have no
  /// deadline until their acknowledgement comes back, so the two copies of one
  /// message count down from one event rather than from two: see
  /// `lib/rotelyx/ephemeral.dart`.
  ///
  /// Opening the conversation is what counts as reading it. There is no
  /// scroll position to consult and no per message visibility test, and adding
  /// one would be a more precise answer to a question nobody asked: the timer
  /// says "gone a minute after you have seen this", and the conversation being
  /// open is the honest reading of that.
  void _startBurnClocks() {
    final c = _conversation;
    if (c == null) return;

    // The service does the work, so this screen and the end to end harness
    // exercise the same path rather than two that agree today.
    if (!rotelyx.markBurnRead(c.id)) return;
    _conversation = store.load(c.id);
  }

  /// Remove anything whose deadline has passed, after it has burnt.
  void _sweep() {
    final c = _conversation;
    if (c == null || !mounted) return;

    final expired =
        c.messages.where((m) => m.burnt && !_burning.contains(m.at)).toList();

    // A message that should be counting and is not gets a clock here. Cheap,
    // and it means no single path has to be the one that remembers.
    _startBurnClocks();

    if (expired.isEmpty) {
      // Still repaint, because the countdowns on screen are ticking.
      if (c.messages.any((m) => m.burnAt != null)) setState(() {});
      return;
    }

    // Marked as burning; the widget calls back when the animation is done.
    setState(() => _burning.addAll(expired.map((m) => m.at)));
  }

  /// Choose how long the next message survives after it is read.
  Future<void> _pickBurn() async {
    final t = RotelyxThemeScope.of(context);

    final chosen = await showModalBottomSheet<int?>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Metrics.radius)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Metrics.wide),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Destroy after reading',
                  style: Type.title.copyWith(color: t.text)),
              const SizedBox(height: 6),
              Text(
                'The clock starts when they open it, not when it arrives. Both '
                'copies go: theirs and the one on this device.',
                style: Type.small.copyWith(color: t.muted),
              ),
              const SizedBox(height: Metrics.pad),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final seconds in burnChoices)
                    GestureDetector(
                      onTap: () => Navigator.of(sheet).pop(seconds),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: seconds == _burnSeconds
                              ? Tone.accent
                              : t.raised,
                          borderRadius: BorderRadius.circular(Metrics.pill),
                        ),
                        child: Text(burnLabel(seconds),
                            style: Type.label.copyWith(
                                color: seconds == _burnSeconds
                                    ? Colors.white
                                    : t.text)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Metrics.pad),
              RxButton('Keep messages',
                  weight: Weight.quiet,
                  wide: true,
                  onTap: () => Navigator.of(sheet).pop(-1)),
              const SizedBox(height: Metrics.gap),
              const RxNote(
                'Nothing here reaches into the other device. Their client '
                'removes its copy because it agreed to, and a recipient who '
                'wants one has a camera pointed at the screen. What this does '
                'deliver is that neither phone keeps it afterwards.',
                title: 'What this does and does not do',
              ),
            ],
          ),
        ),
      ),
    );

    if (chosen == null || !mounted) return;
    setState(() => _burnSeconds = chosen == -1 ? null : chosen);
  }

  /// The reactions offered, and why there are six of them.
  ///
  /// A fixed row rather than a keyboard. Every emoji is a message with an emoji
  /// in it as far as the wire is concerned, so an open picker would not cost
  /// anything technically; it would cost the thing a reaction is for, which is
  /// answering without composing. Six fit across a phone without scrolling.
  static const _offered = ['\u2764\ufe0f', '\ud83d\udc4d', '\ud83d\ude02',
      '\ud83d\ude2e', '\ud83d\ude22', '\ud83d\ude4f'];

  Future<void> _pickReaction(StoredMessage message) async {
    final t = RotelyxThemeScope.of(context);
    final mine = message.reactions.entries
        .where((e) => e.value.contains(rotelyx.displayName))
        .map((e) => e.key)
        .toSet();

    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Metrics.pad, vertical: Metrics.gap),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final emoji in _offered)
                InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.of(sheet).pop(emoji),
                  child: Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: mine.contains(emoji)
                          ? Tone.accent.withOpacity(0.18)
                          : Colors.transparent,
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 26)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (chosen == null || !mounted) return;

    // Tapping one already sent takes it back, which is the only way to remove
    // one and the behaviour every person tries first.
    final removing = mine.contains(chosen);
    if (!rotelyx.react(at: message.at, emoji: chosen, remove: removing)) return;

    // Shown here as well as sent, because the other side's copy is the one
    // the signal changes and ours has to be changed by us.
    final c = _conversation;
    if (c == null) return;

    for (var i = 0; i < c.messages.length; i++) {
      final m = c.messages[i];
      if (m.at != message.at || m.mine != message.mine) continue;

      final next = {
        for (final entry in m.reactions.entries)
          entry.key: List<String>.of(entry.value)
      };
      final people = next.putIfAbsent(chosen, () => <String>[]);
      if (removing) {
        people.remove(rotelyx.displayName);
        if (people.isEmpty) next.remove(chosen);
      } else if (!people.contains(rotelyx.displayName)) {
        people.add(rotelyx.displayName);
      }

      setState(() => c.messages[i] = m.copyWith(reactions: next));
      store.save(c);
      break;
    }
  }

  /// Called by the animation when a message has finished burning.
  void _gone(StoredMessage message) {
    final c = _conversation;
    if (c == null || !mounted) return;

    setState(() {
      c.messages.removeWhere((m) => m.at == message.at && m.mine == message.mine);
      _burning.remove(message.at);
    });
    store.save(c);
    widget.onChanged?.call();
  }

  /// Opening a conversation is what makes it read.
  ///
  /// The count in the list is derived from `lastOpened` rather than kept as a
  /// number, so this is the only place that has to remember anything, and a
  /// path that forgets to decrement cannot leave a badge stuck forever.
  void _markRead() {
    final c = _conversation;
    if (c == null) return;
    // Taken down whether or not there was anything unread: a notification can
    // outlive the state that produced it, and one left in the shade for a
    // conversation being read is the kind of small wrongness people notice.
    alerts.read(c.id);
    // Off unless this conversation asked for it. The switch is on the contact
    // sheet and it says what an envelope per read costs.
    rotelyx.sendReadReceipt(c.id);
    if (!c.hasUnread) return;

    c.lastOpened = DateTime.now();
    c.unread = false;
    store.save(c);
    widget.onChanged?.call();
  }

  void _replyTo(StoredMessage message) {
    setState(() => _replyingTo = message);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final c = _conversation;

    if (c == null) {
      return Container(
        color: t.backdrop,
        child: Center(
          child: Text('This conversation could not be opened.',
              style: Type.body.copyWith(color: t.muted)),
        ),
      );
    }

    // A swipe from the left edge closes the conversation, the way every phone
    // in the world says it should. Null on a wide screen, where the list is
    // beside this rather than behind it and there is nothing to go back to.
    return SwipeBack(
      onBack: widget.onBack,
      child: Container(
      color: t.backdrop,
      child: SafeArea(
        child: Column(
          children: [
            _Header(
              onOpenContact: () => ContactSheet.open(
                context,
                widget.conversationId,
                onChanged: () {
                  setState(() =>
                      _conversation = store.load(widget.conversationId));
                  widget.onChanged?.call();
                },
              ),
              title: c.title,
              onBack: widget.onBack,
              onToggleSafety: () => setState(() => _showSafety = !_showSafety),
              onAddMember: _addMember,
              expanded: _showSafety,
              resuming: _resuming,
              resumable: store.sessionBlob(widget.conversationId) != null,
            ),
            if (_showSafety) _SafetyPanel(),
            if (!_resuming &&
                rotelyx.state != RotelyxState.joined &&
                store.sessionBlob(widget.conversationId) == null)
              const Padding(
                padding: EdgeInsets.fromLTRB(
                    Metrics.pad, Metrics.pad, Metrics.pad, 0),
                child: RxNote(
                  'This transcript is on the device, but the group state was '
                  'never sealed, so there is nothing to rejoin. Pair again with '
                  'the same person to start a new conversation.',
                  title: 'Readable, not reachable',
                ),
              ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusScope.of(context).unfocus(),
                child: c.messages.isEmpty
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => FocusScope.of(context).unfocus(),
                      child: _Empty(),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(Metrics.pad),
                      // The keyboard closes when the transcript is touched,
                      // including on the gaps between bubbles, which is why
                      // this is on the list rather than on each row.
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: c.messages.length,
                      itemBuilder: (_, i) {
                        final message = c.messages[i];
                        return _Bubble(
                          message: message,
                          showAuthor: _startsRun(c.messages, i),
                          onReply: () => _replyTo(message),
                          // Applied inside `_Bubble`, around the bubble alone.
                          // Wrapping this row put the fire across the whole
                          // width of the conversation with the bubble sitting
                          // untouched beneath it.
                          burning: _burning.contains(message.at),
                          onGone: () => _gone(message),
                          onReact: message.mine
                              ? null
                              : () => _pickReaction(message),
                        );
                      },
                    ),
              ),
            ),
            if (_replyingTo != null)
              _ReplyingTo(
                message: _replyingTo!,
                fallbackAuthor: c.title,
                onCancel: () => setState(() => _replyingTo = null),
              ),
            _Composer(
              controller: _input,
              focus: _focus,
              onSend: _send,
              onAttach: _pickFile,
              burnSeconds: _burnSeconds,
              onBurn: _pickBurn,
            ),
          ],
        ),
      ),
    ));
  }

  /// True when this message starts a new run from one sender, so only the first
  /// of a burst carries a name and the column stays quiet.
  bool _startsRun(List<StoredMessage> all, int i) =>
      i == 0 || all[i - 1].mine != all[i].mine;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.onOpenContact,
    required this.onBack,
    required this.onToggleSafety,
    required this.onAddMember,
    required this.expanded,
    required this.resuming,
    required this.resumable,
  });

  final String title;

  /// Their name, their picture, and what this device does about them.
  final VoidCallback onOpenContact;

  final VoidCallback? onBack;
  final VoidCallback onToggleSafety;
  final VoidCallback onAddMember;
  final bool expanded;
  final bool resuming;

  /// Whether a sealed session exists to come back from. Without one the
  /// transcript is readable and the conversation is not resumable, the two are
  /// different failures and the header should not call both "not connected".
  final bool resumable;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final live = rotelyx.state == RotelyxState.joined;

    return Container(
      // Less horizontal padding than the rest of the app, because this row
      // carries an avatar, two lines of text and two buttons, and on a phone
      // that is already more than it comfortably holds.
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: Icon(Icons.arrow_back, size: 20, color: t.muted),
            ),
          RxAvatar(title, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.label.copyWith(color: t.text, fontSize: 15)),
                const SizedBox(height: 3),
                // Wrap, not Row. A Row here overflowed on a phone: the chips
                // are wider than what is left after an avatar and two icons, so
                // `epoch 2` was drawn underneath the add-member button. Nothing
                // reports that in a release build, and it looked like sloppy
                // spacing rather than a layout that had run out of room.
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // The route is shown because it changes with context and
                    // the user should not have to guess which one they got.
                    RxChip(
                        live
                            ? 'via mailbox'
                            : resuming
                                ? 'reconnecting'
                                : resumable
                                    ? 'offline'
                                    : 'history only',
                        tone: live
                            ? Tone.good
                            : resuming
                                ? Tone.warn
                                : t.faint,
                        icon: live
                            ? Icons.inbox_outlined
                            : resumable
                                ? Icons.cloud_off
                                : Icons.history),
                    // The epoch used to sit here and pushed the row onto a
                    // second line on a phone, which made the header taller than
                    // the name it exists to show. It is a protocol detail and
                    // it now lives in the safety panel, next to the number it
                    // belongs with. The route stays, because it changes with
                    // circumstance and the user should not have to guess.
                    if (live && rotelyx.memberCount > 2)
                      RxChip('${rotelyx.memberCount} here',
                          icon: Icons.group_outlined),
                  ],
                ),
              ],
            ),
          ),
          if (live && rotelyx.memberCount > 1)
            IconButton(
              onPressed: onAddMember,
              tooltip: 'Add someone',
              icon: Icon(Icons.person_add_alt, size: 19, color: t.muted),
            ),
          IconButton(
            onPressed: onOpenContact,
            tooltip: 'Name, picture and notifications',
            icon: Icon(Icons.tune, size: 19, color: t.muted),
          ),
          IconButton(
            onPressed: onToggleSafety,
            tooltip: 'Safety number',
            icon: Icon(expanded ? Icons.verified_user : Icons.verified_user_outlined,
                size: 20, color: expanded ? Tone.accent : t.muted),
          ),
        ],
      ),
    );
  }
}

class _SafetyPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final number = rotelyx.safetyNumber;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Metrics.pad),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Safety number', style: Type.label.copyWith(color: t.muted)),
          const SizedBox(height: 6),
          SelectableText(number ?? 'not ready yet',
              style: Type.numeric.copyWith(color: t.text)),
          const SizedBox(height: 8),
          Text(
            'Read this aloud to the other person. Comparing it here, over the '
            'same connection, proves nothing, that is the one channel an '
            'attacker in the middle would control.',
            style: Type.small.copyWith(color: t.faint),
          ),
          if (rotelyx.roster.length > 1) ...[
            const SizedBox(height: Metrics.pad),
            Text('In this conversation',
                style: Type.label.copyWith(color: t.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final name in rotelyx.roster) RxChip(name),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'These are labels each member chose. The group authenticates '
              'them; nothing outside it does.',
              style: Type.small.copyWith(color: t.faint),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.showAuthor,
    this.onReply,
    this.burning = false,
    this.onGone,
    this.onReact,
  });

  final StoredMessage message;
  final bool showAuthor;
  final VoidCallback? onReply;

  /// Whether this message is being destroyed right now.
  final bool burning;

  /// Called when the fire has finished and the message can be removed.
  final VoidCallback? onGone;

  /// Offer a reaction. Null on our own messages: reacting to yourself is a
  /// thing other applications allow and nobody has ever wanted.
  final VoidCallback? onReact;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final mine = message.mine;

    // Swipe to reply, which is the gesture every messenger now uses for this
    // and therefore the one nobody has to be taught. Dismissible with a
    // confirm that always refuses: the bubble slides, springs back, and the
    // composer picks the message up. Nothing is ever actually dismissed.
    //
    // # Which way it swipes, and why it is not one direction for everything
    //
    // Towards the middle of the screen, always. A bubble on the left is
    // dragged right; a bubble on the right is dragged left.
    //
    // It used to be rightwards for both, which is correct for what they sent
    // and wrong for what you sent: your own bubbles sit against the right edge,
    // and dragging one further right pushes it off the screen it is already
    // touching. The gesture has to move a message away from its own side,
    // because that is the direction there is room in and the direction a thumb
    // reaches.
    final towardsCentre =
        mine ? DismissDirection.endToStart : DismissDirection.startToEnd;

    return Dismissible(
      key: ObjectKey(message),
      direction: onReply == null ? DismissDirection.none : towardsCentre,
      // A quarter of the width either way. Measured from the bubble rather
      // than the screen, so a short message needs a short drag.
      dismissThresholds: {towardsCentre: 0.25},
      confirmDismiss: (_) async {
        onReply?.call();
        return false;
      },
      // The arrow appears on the side the bubble is being dragged away from,
      // which is where the gap opens up.
      background: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(left: mine ? 0 : 18, right: mine ? 18 : 0),
          child: Icon(Icons.reply, size: 18, color: t.faint),
        ),
      ),
      child: _bubble(context, t, mine),
    );
  }

  Widget _bubble(BuildContext context, RotelyxTheme t, bool mine) {
    return Padding(
      padding: EdgeInsets.only(top: showAuthor ? 10 : 2, bottom: 2),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _row(context, t, mine),
          _reactions(context, t, mine),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, RotelyxTheme t, bool mine) {
    return Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          // The burn wraps the bubble and nothing else.
          //
          // It used to wrap the whole row, which is the full width of the
          // conversation, so the shader's front became a horizontal line across
          // the screen with the bubble sitting untouched beneath it. The fire
          // has to be the size of the thing that is burning.
          Flexible(
            child: burning
                ? Burning(
                    key: ValueKey('burn-${message.at.microsecondsSinceEpoch}'),
                    onGone: onGone ?? () {},
                    child: _shell(context, t, mine),
                  )
                : _shell(context, t, mine),
          ),
        ]);
  }

  /// The bubble itself, sized to its content.
  /// The reactions on a message, under its bubble.
  ///
  /// Under rather than overlapping the corner, which is the common treatment
  /// and the one that covers the timestamp on a short message. A row that takes
  /// its own space cannot collide with anything.
  Widget _reactions(BuildContext context, RotelyxTheme t, bool mine) {
    if (message.reactions.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(
          top: 4, left: mine ? 0 : 8, right: mine ? 8 : 0, bottom: 2),
      child: Wrap(
        spacing: 4,
        children: [
          for (final entry in message.reactions.entries)
            Tooltip(
              message: entry.value.join(', '),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: t.raised,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: t.line),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(entry.key, style: const TextStyle(fontSize: 12)),
                    if (entry.value.length > 1) ...[
                      const SizedBox(width: 3),
                      Text('${entry.value.length}',
                          style: Type.small
                              .copyWith(fontSize: 10, color: t.muted)),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _shell(BuildContext context, RotelyxTheme t, bool mine) {
    final body = _shellBody(context, t, mine);
    if (onReact == null) return body;

    // A long press, because a tap already scrolls and a swipe already replies.
    // Nothing here opens on hover: this application is used on a phone first.
    return GestureDetector(onLongPress: onReact, child: body);
  }

  Widget _shellBody(BuildContext context, RotelyxTheme t, bool mine) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.62),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: mine ? t.mine : t.theirs,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(Metrics.bubble),
                  topRight: const Radius.circular(Metrics.bubble),
                  bottomLeft: Radius.circular(mine ? Metrics.bubble : 5),
                  bottomRight: Radius.circular(mine ? 5 : Metrics.bubble),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Body(message: message, mine: mine),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${message.at.hour.toString().padLeft(2, '0')}:'
                        '${message.at.minute.toString().padLeft(2, '0')}',
                        style: Type.small.copyWith(
                            fontSize: 10,
                            color:
                                (mine ? t.mineText : t.faint).withOpacity(0.65)),
                      ),
                      if (message.burnAt != null ||
                          Ephemeral.isEphemeral(message.text)) ...[
                        const SizedBox(width: 5),
                        _Countdown(
                          message: message,
                          colour: mine ? t.mineText : t.faint,
                        ),
                      ],
                      if (mine) ...[
                        const SizedBox(width: 4),
                        // Three states, not two, because "read" and "delivered"
                        // are different facts and only one of them is ever
                        // inferred. A tick that guesses is worse than no tick:
                        // it invents something about the other person.
                        Icon(
                          message.seen
                              ? Icons.done_all
                              : message.inMailbox
                                  ? Icons.done
                                  : Icons.schedule,
                          size: 11,
                          color: message.seen
                              ? const Color(0xFF7DD3A0)
                              : t.mineText.withOpacity(0.65),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
    );
  }
}

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Metrics.wide),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Conversation established',
                style: Type.label.copyWith(color: t.muted)),
            const SizedBox(height: 6),
            Text(
              'Messages travel under tags that rotate every hour. Anyone who '
              'knew the meeting phrase has lost the thread.',
              textAlign: TextAlign.center,
              style: Type.small.copyWith(color: t.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar above the composer while a reply is being written.
///
/// Named and quoted, because a reply with no visible target is a message the
/// sender thinks is attached to something and the reader has to guess about.
class _ReplyingTo extends StatelessWidget {
  const _ReplyingTo({
    required this.message,
    required this.fallbackAuthor,
    required this.onCancel,
  });

  final StoredMessage message;
  final String fallbackAuthor;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final who = message.mine
        ? 'yourself'
        : (message.author.isEmpty ? fallbackAuthor : message.author);

    return Container(
      padding: const EdgeInsets.fromLTRB(Metrics.pad, 8, 8, 0),
      color: t.surface,
      child: Row(
        children: [
          const Icon(Icons.reply, size: 16, color: Tone.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Replying to $who',
                    style: Type.small.copyWith(
                        color: Tone.accent, fontWeight: FontWeight.w600)),
                Text(Quoted.plain(message.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.small.copyWith(color: t.faint)),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            icon: Icon(Icons.close, size: 18, color: t.muted),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.onSend,
    required this.onAttach,
    required this.burnSeconds,
    required this.onBurn,
  });

  final FocusNode focus;

  /// How long the next message survives, or null when it stays.
  final int? burnSeconds;
  final VoidCallback onBurn;

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Container(
      padding: const EdgeInsets.all(Metrics.gap + 2),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            onPressed: onAttach,
            tooltip: 'Attach a file',
            icon: Icon(Icons.attach_file, size: 20, color: t.muted),
          ),

          // Lit when the next message is going to burn, and carrying the
          // duration, because a mode this consequential should never be on
          // without saying so.
          IconButton(
            onPressed: onBurn,
            tooltip: burnSeconds == null
                ? 'Destroy after reading'
                : 'Burns ${burnLabel(burnSeconds!)} after it is read',
            icon: burnSeconds == null
                ? Icon(Icons.local_fire_department_outlined,
                    size: 20, color: t.muted)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.local_fire_department,
                          size: 20, color: Color(0xFFFF7A18)),
                      const SizedBox(width: 3),
                      Text(burnLabel(burnSeconds!),
                          style: Type.small.copyWith(
                              color: const Color(0xFFFF7A18),
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
          ),

          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              focusNode: focus,
              onSubmitted: (_) => onSend(),
              style: Type.body.copyWith(color: t.text),
              decoration: InputDecoration(
                hintText: 'Message',
                hintStyle: Type.body.copyWith(color: t.faint),
                filled: true,
                fillColor: t.raised,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: Metrics.pad, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Metrics.pill),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: Metrics.gap),
          Material(
            color: Tone.accent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onSend,
              child: const Padding(
                padding: EdgeInsets.all(11),
                child: Icon(Icons.arrow_upward, size: 19, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// A bubble's contents: text, a picture, or a file the mailbox carried whole.
/// How long a message has left, beside its timestamp.
///
/// Turns from the bubble's own colour to the fire's as it runs down, so the
/// last few seconds are visible without anything moving or flashing. The
/// message is about to be destroyed; the interface does not also need to shout.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.message, required this.colour});

  final StoredMessage message;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final left = message.burnIn;

    // Sent, with a timer, and not read yet. The flame is shown unlit and the
    // place where a number goes is held rather than filled, because the answer
    // to "how long is left" is not zero and is not a duration either: nothing
    // is counting until they open it. A number here would be a guess, and the
    // dash is the only honest thing to put in its place.
    if (left == null) {
      return _row(context, '-', urgent: false, lit: false);
    }

    final seconds = left.inSeconds;
    final urgent = seconds <= 10;

    final String label;
    if (seconds >= 86400) {
      label = '${left.inDays}d';
    } else if (seconds >= 3600) {
      label = '${left.inHours}h';
    } else if (seconds >= 60) {
      label = '${left.inMinutes}m';
    } else {
      label = '${seconds}s';
    }

    return _row(context, label, urgent: urgent, lit: true);
  }

  Widget _row(BuildContext context, String label,
      {required bool urgent, required bool lit}) {
    final shade = urgent
        ? const Color(0xFFFF7A18)
        : colour.withOpacity(lit ? 0.55 : 0.35);

    return Tooltip(
      message: lit
          ? 'Destroyed when this reaches zero, on both devices'
          : 'Starts counting when they read it',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department, size: 11, color: shade),
          const SizedBox(width: 2),
          Text(label,
              style: Type.small.copyWith(
                  fontSize: 10,
                  fontWeight: urgent ? FontWeight.w700 : FontWeight.w500,
                  color: shade)),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.message, required this.mine});

  final StoredMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final fg = mine ? t.mineText : t.theirsText;

    // The timer wraps everything else, so it comes off first and what is inside
    // is an ordinary message, a reply, or a file.
    final body = Ephemeral.plain(message.text);

    // A reply carries a copy of what it answers, because there is no message id
    // on the wire to point at. See `lib/rotelyx/quoted.dart`.
    final quoted = Quoted.decode(body);
    if (quoted != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // A smaller bubble inside the bubble, in this application's own shape
          // language: same corner family, scaled down, tinted rather than
          // outlined.
          //
          // Deliberately not the accent bar down the left edge. That is the
          // default every framework reaches for, and the direction the field
          // has actually moved is the opposite one: WhatsApp's 2026 redesign
          // removed the borders around embedded media and rounded everything
          // further, on the reasoning that a quote is part of the message
          // rather than a citation attached to it. A rule down the side is
          // chrome that says "this is quoted" in a bubble whose shape and tint
          // already say it.
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.fromLTRB(11, 7, 11, 8),
            decoration: BoxDecoration(
              color: (mine ? Colors.white : t.text).withOpacity(0.09),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(Metrics.bubble - 6),
                topRight: const Radius.circular(Metrics.bubble - 6),
                bottomLeft: Radius.circular(mine ? Metrics.bubble - 6 : 4),
                bottomRight: Radius.circular(mine ? 4 : Metrics.bubble - 6),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(quoted.author,
                    style: Type.small.copyWith(
                        fontSize: 11.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.1,
                        color: fg.withOpacity(0.9))),
                const SizedBox(height: 1),
                Text(quoted.excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Type.small.copyWith(
                        fontSize: 12.5,
                        height: 1.3,
                        color: fg.withOpacity(0.62))),
              ],
            ),
          ),
          SelectableText(quoted.reply, style: Type.body.copyWith(color: fg)),
        ],
      );
    }

    final file = Attachment.decode(body);

    if (file == null) {
      return SelectableText(body, style: Type.body.copyWith(color: fg));
    }

    if (file.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(file.bytes,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _FileRow(file: file, fg: fg)),
      );
    }
    return _FileRow(file: file, fg: fg);
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.fg});

  final Attachment file;
  final Color fg;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined, size: 20, color: fg),
          const SizedBox(width: 9),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.label.copyWith(color: fg)),
                Text(file.readableSize,
                    style: Type.small.copyWith(color: fg.withOpacity(0.7))),
              ],
            ),
          ),
        ],
      );
}
