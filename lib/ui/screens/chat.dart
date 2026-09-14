/// One conversation.
///
/// The safety number sits at the top rather than behind a menu. It is the only
/// thing that detects the failure pairing cannot prevent, someone who learned
/// the phrase early and answered in the intended party's place, and a check
/// hidden behind two taps is a check nobody performs.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../rotelyx/invite_link.dart';
import '../../platform/incoming_link.dart';
import '../../platform/share.dart';
import 'package:flutter/services.dart';

import '../../platform/file_pick.dart';

import '../../rotelyx/alerts.dart';
import '../../rotelyx/attachment.dart';
import '../../rotelyx/card.dart';
import '../../platform/pasted.dart';
import '../../rotelyx/gif_codec.dart';
import '../../rotelyx/photo_codec.dart';

import '../../rotelyx/ephemeral.dart';
import '../../rotelyx/media_link.dart';
import '../../rotelyx/quoted.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../../rotelyx/signal.dart';
import '../burn.dart';
import '../link_card.dart';
import '../gestures.dart';
import '../../rotelyx/calls.dart';
import 'contact.dart';
import 'picture.dart';
import '../photo.dart';
import '../theme.dart';
import '../widgets.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversationId,
    this.onBack,
    this.onChanged,
    this.swipeToClose = true,
  });

  final String conversationId;
  final VoidCallback? onBack;
  final VoidCallback? onChanged;

  /// Whether this screen handles the edge swipe itself.
  ///
  /// False when something above it is sliding this screen and already reading
  /// the drag. Two handlers on one gesture is one that fights: the screen
  /// would follow the finger and then be closed a second time by its own.
  final bool swipeToClose;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  StoredConversation? _conversation;
  bool _showSafety = false;

  /// Something the conversation said about itself, for a few seconds.
  String? _notice;
  Timer? _noticeTimer;

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

  /// When this transcript was opened.
  ///
  /// Only messages that arrive after it animate in. Without this, opening a
  /// conversation replays every message in it, and a long history turns into a
  /// wall of moving text that has to finish before it can be read.
  final _openedAt = DateTime.now();

  /// Who speaks from which side of the group.
  final _sides = _Sides();

  /// Messages this screen has drawn at least once, and the few that were given
  /// an entrance when they first appeared. Both are decided once: see the
  /// comment at the builder for the hole that changing one's mind leaves.
  final Set<int> _drawn = {};
  final Set<int> _entering = {};

  /// The moment this conversation was last looked at, as it stood when this
  /// screen opened. Null when it has never been opened.
  DateTime? _readUpTo;

  /// Whether the screen has already been taken to the unread mark.
  bool _wentToUnread = false;

  /// Take the conversation to where reading stopped, once, on opening.
  ///
  /// A conversation opens at its newest message, which is right when there is
  /// nothing waiting. When there is, the newest message is the end of a pile
  /// nobody has read, and starting at the end of a pile means scrolling back
  /// through it to find the top. So: if something arrived since the last look,
  /// open at the first of it, with the mark directly above.
  void _openWhereReadingStopped(StoredConversation c) {
    if (_wentToUnread) return;
    final mark = _unreadMark(c);
    if (mark == null) {
      _wentToUnread = true;
      return;
    }
    // Nothing to go to until the message is in the transcript this screen
    // holds, which for a backlog is a moment after opening.
    final at = c.messages
        .where((m) => m.at.millisecondsSinceEpoch == mark)
        .map((m) => m.at)
        .firstOrNull;
    if (at == null) return;

    _wentToUnread = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Instantly: see `_reveal`. Opening is not a journey, and the more
      // unread there is the worse an animated one gets.
      if (mounted) _reveal(at, instant: true);
    });
  }

  /// The first message that arrived after that, which is where the mark goes.
  ///
  /// Worked out once, from the transcript as it was on opening, so the mark
  /// stays put while the rest of the backlog lands underneath it.
  int? _firstUnread;
  bool _foundUnread = false;

  int? _unreadMark(StoredConversation c) {
    if (_foundUnread) return _firstUnread;
    final since = _readUpTo;
    if (since == null) {
      _foundUnread = true;
      return null;
    }
    for (final m in c.messages) {
      if (m.mine) continue;
      if (m.at.isAfter(since)) {
        _firstUnread = m.at.millisecondsSinceEpoch;
        break;
      }
    }
    _foundUnread = true;
    return _firstUnread;
  }

  /// Whether the newest message is off the bottom of the screen.
  ///
  /// The list is reversed, so offset zero is the bottom and reading older
  /// messages means a growing offset. A screen and a half of it is far enough
  /// that the way back is worth offering and near enough that it is not
  /// offered for a nudge.
  bool _away = false;

  void _watchTheScroll() {
    if (!_scroll.hasClients) return;
    final away = _scroll.offset > 600;
    final atTheEnd = _scroll.offset <= 80;
    if (away != _away || (atTheEnd && _below > 0)) {
      if (!mounted) return;
      setState(() {
        _away = away;
        if (atTheEnd) _below = 0;
      });
    }
  }

  /// How many messages have arrived while the newest one was off the screen.
  ///
  /// The button says so rather than the list moving: being taken somewhere
  /// while reading is the thing people complain about, and a number on a
  /// button is the same information without the interruption.
  int _below = 0;

  /// One key, on the one bubble a jump is going to.
  ///
  /// # Why exactly one
  ///
  /// Scrolling to a message needs a `GlobalKey` on it, and the first version
  /// put one on every bubble. A global key is a promise that a widget is
  /// unique in the whole tree, and moving one makes Flutter take the element
  /// out and put it back: every message that arrives shifts every row in a
  /// reversed list by one, so every visible bubble was detached and rebuilt on
  /// every arrival, pictures and all. That is the flicker -- the second one,
  /// the one inside a conversation, which he reported after the list stopped
  /// doing it.
  ///
  /// So the ordinary bubble is keyed by its own message, which is local and
  /// cheap and lets Flutter reuse the element where it is, and the global key
  /// is attached to a single row only while a jump is looking for it.
  final GlobalKey _target = GlobalKey();
  DateTime? _targetAt;

  /// The message being pointed at after a jump, so it can be seen to be the
  /// one. Cleared a moment later.
  DateTime? _flash;
  Timer? _flashOff;

  /// Go to the message a reply is answering.
  ///
  /// There is no message id on the wire, on purpose: an id is a handle the
  /// mailbox could correlate envelopes with. A reply carries a copy of the
  /// opening of what it answers instead, so finding the original is a search
  /// backwards through this device's own transcript for the message that copy
  /// was taken from.
  ///
  /// It can fail honestly: the message being answered may have arrived before
  /// this device was in the conversation, or have been deleted here, or have
  /// burned. Saying so is better than scrolling somewhere arbitrary.
  void _goToQuoted(List<StoredMessage> messages, int from, Quoted quoted) {
    final want = quoted.excerpt.trim();
    if (want.isEmpty) return;

    /// Whether one of these is the opening of the other.
    ///
    /// A quote is a copy of the first hundred and twenty characters with an
    /// ellipsis on the end, so the two are never equal and the last character
    /// compared is never the same one. Comparing the whole overlap therefore
    /// failed on every quote of a long message, which is what "that message is
    /// not on this device" turned out to mean.
    String opening(String text) {
      var out = text.trim();
      while (out.isNotEmpty &&
          (out.endsWith('…') || out.endsWith('.') || out.endsWith(' '))) {
        out = out.substring(0, out.length - 1);
      }
      // Whitespace inside it is normalised too: a quote carries the text with
      // its newlines turned into spaces by whoever built it.
      return out.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    }

    bool sameOpening(String a, String b) {
      final one = opening(a);
      final two = opening(b);
      if (one.isEmpty || two.isEmpty) return false;
      final n = one.length < two.length ? one.length : two.length;
      // Long enough not to match two different messages that begin the same
      // way, short enough to survive the trimming above.
      if (n < 12) return one == two;
      return one.substring(0, n) == two.substring(0, n);
    }

    for (var i = from - 1; i >= 0; i--) {
      final plain = Ephemeral.plain(Quoted.plain(messages[i].text));
      final glimpse = attachmentGlimpse(plain);
      if (sameOpening(plain, want) || (glimpse != null && glimpse == want)) {
        _reveal(messages[i].at);
        return;
      }
    }

    _say('That message is not on this device any more.');
  }

  /// Scroll to one message and mark it, building the way there if it is far up.
  ///
  /// `ListView.builder` only holds what is near the screen, so the anchor for
  /// something a hundred messages back does not exist to scroll to yet. The
  /// list is walked towards it a screen at a time until it does, which is what
  /// every messenger that has this feature does underneath.
  ///
  /// # Why there are two speeds
  ///
  /// Tapping a quote is a journey somebody asked for: it should be animated,
  /// because seeing the conversation move is what says where you went and
  /// makes the way back obvious.
  ///
  /// Opening a conversation at the first unread message is not a journey. With
  /// ninety unread, the animated walk took seconds of watching the backlog
  /// scroll past before it settled -- "tuve que esperar a que el scroll llegue
  /// arriba" -- and that gets worse the more there is to read, which is
  /// exactly backwards. `instant` jumps instead: the same walk, no animation
  /// and no waiting between steps, so it lands in a few frames however far
  /// back the mark is.
  Future<void> _reveal(DateTime at, {bool instant = false}) async {
    setState(() {
      _flash = at;
    });
    _flashOff?.cancel();
    _flashOff = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _flash = null);
    });

    if (_targetAt != at) setState(() => _targetAt = at);
    for (var step = 0; step < 60; step++) {
      final context = _target.currentContext;
      if (context != null) {
        await Scrollable.ensureVisible(
          context,
          alignment: 0.35,
          duration: instant ? Duration.zero : const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
        return;
      }
      if (!_scroll.hasClients) return;

      // Backwards in time is upwards on the screen and, in a reversed list,
      // forwards in the scroll offset.
      final position = _scroll.position;
      // A whole screen at a time when jumping, rather than the four fifths an
      // animation uses to keep its overlap readable: nobody is reading this
      // one, and fewer steps is less to build.
      final next = position.pixels +
          position.viewportDimension * (instant ? 1.0 : 0.8);
      if (next >= position.maxScrollExtent) {
        if (instant) {
          _scroll.jumpTo(position.maxScrollExtent);
        } else {
          await _scroll.animateTo(position.maxScrollExtent,
              duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        await SchedulerBinding.instance.endOfFrame;
        if (!mounted) return;
        final top = _target.currentContext;
        if (top != null) {
          await Scrollable.ensureVisible(top,
              alignment: 0.35,
              duration:
                  instant ? Duration.zero : const Duration(milliseconds: 200));
        }
        return;
      }
      if (instant) {
        _scroll.jumpTo(next);
        // One frame, which is what it takes for the list to build the part
        // that just came into view, and nothing more.
        await SchedulerBinding.instance.endOfFrame;
      } else {
        await _scroll.animateTo(next,
            duration: const Duration(milliseconds: 90), curve: Curves.linear);
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      if (!mounted) return;
    }
  }

  @override
  void initState() {
    super.initState();
    _shut = store.isLocked(widget.conversationId) &&
        !store.isOpened(widget.conversationId);

    _conversation = store.load(widget.conversationId);

    // Where reading stopped, read before `_markRead` moves it.
    //
    // Opening at the newest message is right -- that is where a conversation
    // is -- but it leaves somebody who has forty unread messages with no idea
    // which ones they are. So the moment they last looked is kept, the first
    // message after it is marked, and the mark stays where it was put for as
    // long as the screen is open: a line that moves while you read is a line
    // that tells you nothing.
    _readUpTo = _conversation?.lastOpened;
    _scroll.addListener(_watchTheScroll);
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
      _reloadSoon();
    });

    // Things that were refused while the conversation still works. A spent
    // allowance is the one this was built for: the deposit did not happen and
    // nothing else on this screen would ever say so, because a message that is
    // not stored looks the same from here as one that is.
    // Shown under the header rather than as a bar over the compose box: a
    // notice about the conversation belongs where the conversation's own
    // state is (who is here, whether it is connected), and a bar at the
    // bottom covered the field somebody was typing into.
    rotelyx.notices.listen((message) {
      if (!mounted) return;
      _noticeTimer?.cancel();
      setState(() => _notice = message);
      _noticeTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _notice = null);
      });
    });
    _resumeIfNeeded();
  }

  /// Reload the conversation, at most once every fifth of a second.
  ///
  /// The session reports a change for every message, every receipt, every
  /// commit and every member who arrives, and in a group of thirteen people
  /// that is several a second. Each one used to reopen the vault, decrypt the
  /// whole transcript and rebuild every object in it, which is the work that
  /// made the screen stutter and blink while a burst came in.
  ///
  /// Coalescing them loses nothing: what is wanted is the state after the
  /// burst, not one frame per event in it.
  void _reloadSoon() {
    if (_reloadPending) return;
    _reloadPending = true;
    Timer(const Duration(milliseconds: 200), () {
      _reloadPending = false;
      if (!mounted) return;
      setState(() => _conversation = store.load(widget.conversationId));
    });
  }

  bool _reloadPending = false;

  /// One line under the header, for something this screen has to say itself.
  void _say(String message) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  void dispose() {
    if (alerts.openConversation == widget.conversationId) {
      alerts.openConversation = null;
    }
    _tick?.cancel();
    _flashOff?.cancel();
    _scroll.removeListener(_watchTheScroll);
    _noticeTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Whether the service is joined *to this conversation*.
  ///
  /// Not the same question as whether it is joined at all, and the difference
  /// is not cosmetic: the state alone is true whenever any conversation is
  /// live, so acting on it sent messages, attachments and invitations into
  /// whichever one happened to be open last. Every place in this screen that
  /// used to ask the shorter question now asks this one.
  bool get _live =>
      rotelyx.state == RotelyxState.joined &&
      rotelyx.conversationId == widget.conversationId;

  /// Reopen the MLS session for this conversation when it is not the live one.
  ///
  /// # What this used to get wrong
  ///
  /// It asked whether *a* conversation was live rather than whether *this* one
  /// was. Opening a second conversation while the first was still joined left
  /// the first one's session in place, so the transcript on screen belonged to
  /// one conversation and everything typed into it went to another.
  ///
  /// The forwarding path a few hundred lines below already compared
  /// `rotelyx.conversationId` for exactly this reason. This now does the same.
  Future<void> _resumeIfNeeded() async {
    if (_live) return;

    // A conversation with yourself is founded on first open rather than paired
    // into existence, so having no sealed session is what is expected the first
    // time rather than a reason to give up on it.
    final self = widget.conversationId == RotelyxService.selfConversationId;
    if (!self && store.sessionBlob(widget.conversationId) == null) return;

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
    // Coalesced, like every other reason to reload: a burst of arrivals is one
    // update of the screen, not one per message. See `_reloadSoon`.
    _reloadSoon();
    // After the reload, not before. The service is what writes a message down,
    // so at the moment `send` returns this screen still holds the conversation
    // as it was, and starting clocks on that copy started none: the message
    // whose clock needed starting was not in it yet.
    _startBurnClocks();
    // Arriving while the conversation is open counts as read, or the badge
    // appears on a conversation the user is looking at.
    _markRead();
    widget.onChanged?.call();
    if (_scroll.hasClients && _scroll.offset > 80) {
      // Not at the end: say that something arrived instead of going to it.
      setState(() => _below++);
    } else {
      _toBottom(always: false);
    }
  }

  void _toBottom({bool always = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      // Reading anywhere but the very bottom is not interrupted.
      //
      // The list is reversed, so the bottom is offset zero. This used to allow
      // a screen of slack, which meant a message arriving while somebody was a
      // paragraph up still yanked them down. Now anything but the bottom is
      // treated as deliberate, and what arrives is announced on the button
      // instead of being scrolled to.
      if (!always && _scroll.offset > 80) return;
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  /// Ask which, then open that.
  ///
  /// The button used to go straight to the file system, which is the wrong
  /// question asked politely: almost everything anybody attaches to a message
  /// is a photograph, and a photograph is not a folder to go and find. So
  /// pictures are offered first, and everything else is still one tap away.
  Future<void> _attach() async {
    final t = RotelyxThemeScope.of(context);
    final images = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Metrics.radius)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          // Room for the navigation bar underneath.
        //
        // A bottom sheet is drawn against the bottom of the window, and on a
        // phone that draws edge to edge the bottom of the window is behind the
        // system's own buttons. So the last control on each of these sat under
        // them: visible, and not reachable.
        //
        // `viewPaddingOf`, not `paddingOf`. This context sits inside the
        // screen's SafeArea, and SafeArea consumes `padding` for everything
        // beneath it, so `paddingOf(context).bottom` read zero here and the
        // sheet went on sitting behind the buttons after the first fix. The
        // view padding is the one SafeArea leaves alone.
        padding: EdgeInsets.fromLTRB(
          Metrics.wide,
          Metrics.wide,
          Metrics.wide,
          Metrics.wide + MediaQuery.viewPaddingOf(context).bottom,
        ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Attach', style: Type.title.copyWith(color: t.text)),
              const SizedBox(height: Metrics.pad),
              RxButton('Photo',
                  icon: Icons.photo_outlined,
                  wide: true,
                  onTap: () => Navigator.of(sheet).pop(true)),
              const SizedBox(height: Metrics.gap),
              RxButton('File',
                  weight: Weight.secondary,
                  icon: Icons.insert_drive_file_outlined,
                  wide: true,
                  onTap: () => Navigator.of(sheet).pop(false)),
              const SizedBox(height: Metrics.pad),
              // What a file can be, said before somebody picks one.
              //
              // A photograph is shrunk to fit and a file is not, so the same
              // limit means very different things to the two of them. Video
              // is the case that matters: there is no encoder for it here, so
              // anything long enough to be worth sending is refused, and
              // finding that out after choosing is the annoying way round.
              RxNote(
                'A photograph is shrunk to fit. A file is sent as it is, so '
                'it has to be under ${readableBytes(store.capabilityToken == null ? freeAttachmentBytes : maxAttachmentBytes)}. '
                'Video is not shrunk either, so all but the shortest clips '
                'are refused.',
                title: 'What fits',
              ),
            ],
          ),
        ),
      ),
    );

    // Closed without choosing.
    if (images == null || !mounted) return;
    await _pickFile(images: images);
  }

  Future<void> _pickFile({bool images = false}) async {
    // What one envelope holds, worked out before the picker opens.
    final budget = store.capabilityToken == null
        ? freeAttachmentBytes
        : maxAttachmentBytes;

    final PickedFile? file;
    try {
      // A picture is allowed well over the budget and a file is not.
      //
      // A photograph is shrunk before it is sent, so holding the picker to
      // the envelope size refused a camera photograph before anything had a
      // chance to make it smaller. Nothing shrinks a file, so its real limit
      // is the one to apply at the picker: refusing there costs nothing,
      // while letting it through means reading tens of megabytes off the
      // disk in order to say no afterwards.
      file = await pickFile(
          maxBytes: images ? 24 * 1024 * 1024 : budget, images: images);
    } on NoFilePicker catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${e.message}. One message holds '
              '${readableBytes(budget)}, because the mailbox pads every '
              'envelope to a fixed ladder and refuses anything over the top '
              'of it.')));
      return;
    }

    // Null means the picker was closed without choosing, which is not a failure
    // and is not worth a message.
    if (file == null) return;

    await _sendPicture(file.bytes, file.mime, name: file.name);
  }

  /// Shrink whatever this is until one envelope holds it, then send it.
  ///
  /// The one path for everything that is not typed: a file from the picker, a
  /// picture the keyboard handed over on Android, one taken off the clipboard
  /// on iOS. They differ in where the bytes came from and in nothing after
  /// that, and two paths would be two sets of limits that agreed until one of
  /// them was changed.
  Future<void> _sendPicture(Uint8List raw, String type,
      {String name = 'picture'}) async {
    var bytes = raw;
    var mime = type;

    // What one envelope will actually hold.
    //
    // Without a capability token the mailbox takes 64 KiB, and it refuses the
    // deposit rather than trimming it, so a picture aimed at the paid ceiling
    // was sealed, sent, and bounced. The person saw a failure and no reason.
    final budget = store.capabilityToken == null
        ? freeAttachmentBytes
        : maxAttachmentBytes;

    // An animation stays one.
    //
    // A GIF used to come through the branch below, which decodes with
    // `dart:ui` and re-encodes as a still: what arrived at the other end was
    // the first frame, and nothing said the rest had gone. Judged by the
    // file's own header rather than by the type it was handed over as,
    // because a picker names a file by its extension and a clipboard by
    // whatever put it there.
    if (isGif(bytes)) {
      final fitted = await fitAnimation(bytes, maxBytes: budget);
      if (fitted != null) {
        if (!mounted || !_live) return;
        _hold(Attachment(name: name, mime: 'image/gif', bytes: fitted));
        return;
      }
      // A single frame animation, or one that will not come down far enough.
      // Falls through to the still path, which is a better picture than a
      // ruined animation and is what the file amounts to anyway.
    }

    if (mime.startsWith('image/')) {
      // Through this application's own codec rather than the platform's.
      //
      // `photo_codec.dart` says why at length. The short of it is that the
      // engine will only re-encode as PNG, and PNG of a photograph at 44 KiB
      // is three hundred pixels across. This holds a thousand.
      final fitted = await fitPicture(bytes, maxBytes: budget);
      if (fitted == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('That picture will not fit in one message.')));
        return;
      }
      bytes = fitted;
      mime = photoMime;
    } else if (bytes.length > budget) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That file is ${readableBytes(bytes.length)} and the '
              'limit is ${readableBytes(budget)}.')));
      return;
    }

    if (!mounted) return;

    // Same fault the composer had: an attachment sent on the shorter question
    // lands in whichever conversation is live, which for a file is worse than
    // for a sentence.
    if (!_live) return;
    _hold(Attachment(name: name, mime: mime, bytes: bytes));
  }

  /// A picture chosen but not sent yet, waiting for whatever is said with it.
  ///
  /// Picking a picture used to send it on the spot, so saying something about
  /// it was a second message: two bubbles, two notifications, and an order
  /// the other phone does not guarantee. Now it waits in the composer, the way
  /// every messenger people already use does it, and the line typed next
  /// travels inside the same message.
  Attachment? _waiting;

  void _hold(Attachment file) {
    setState(() => _waiting = file);
    _focus.requestFocus();
  }

  /// Send a file, through the same timer a sentence goes through.
  ///
  /// # Why this is not `rotelyx.send` directly
  ///
  /// It was, and a picture set to burn did not. The timer is applied in
  /// `_send`, which is the path a typed message takes, and an attachment
  /// went straight past it: the flame was lit, the composer was orange, and
  /// what arrived at the other end stayed there for good.
  ///
  /// A picture is the thing people most mean to have disappear, so this is
  /// the worst place for that gap to have been.
  void _sendAttachment(Attachment file) {
    final seconds = _burnSeconds;
    final body = file.encode();
    rotelyx.send(seconds == null
        ? body
        : Ephemeral.wrap(seconds: seconds, body: body).encode());
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
      // Allowed to be as tall as it needs, and to scroll when that is more
      // than the screen has. Without this a sheet is capped at a fraction of
      // the height and whatever does not fit is simply cut off at the bottom,
      // which on a phone with a soft keyboard or large text is the last
      // button.
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Metrics.radius)),
      ),
      builder: (_) => SingleChildScrollView(
        child: Padding(
        // Room for the navigation bar underneath.
        //
        // A bottom sheet is drawn against the bottom of the window, and on a
        // phone that draws edge to edge the bottom of the window is behind the
        // system's own buttons. So the last control on each of these sat under
        // them: visible, and not reachable.
        //
        // `viewPaddingOf`, not `paddingOf`. This context sits inside the
        // screen's SafeArea, and SafeArea consumes `padding` for everything
        // beneath it, so `paddingOf(context).bottom` read zero here and the
        // sheet went on sitting behind the buttons after the first fix. The
        // view padding is the one SafeArea leaves alone.
        padding: EdgeInsets.fromLTRB(
          Metrics.wide,
          Metrics.wide,
          Metrics.wide,
          Metrics.wide + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add someone', style: Type.title.copyWith(color: t.text)),
            const SizedBox(height: Metrics.gap),
            Text(
              'A link makes a new place for somebody to join this '
              'conversation. The one before it stops working, so an invitation '
              'you sent and thought better of closes when you make another.',
              style: Type.body.copyWith(color: t.muted),
            ),
            const SizedBox(height: Metrics.pad),
            RxButton('Make a link and send it',
                icon: Icons.ios_share,
                wide: true,
                onTap: () async {
                  // A fresh place rather than the phrase this conversation
                  // started with: the address is a hash of that phrase, and a
                  // hash only goes one way, so the phrase is nowhere on this
                  // device. "Give them the same phrase" was the only thing
                  // that could be said before, and it only worked for whoever
                  // still remembered it.
                  final code = await rotelyx.newInvitationHere();
                  if (code == null) return;

                  final link = meetingLink(code, rotelyx.mailboxUrl);
                  final shared = await shareText(link,
                      title: 'Join this conversation',
                      subject: 'A private conversation');
                  if (shared) return;

                  await Clipboard.setData(ClipboardData(text: link));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied')));
                  }
                }),
            const SizedBox(height: Metrics.pad),
            const RxNote(
              'Everybody already here gets new keys the moment somebody '
              'joins, so a newcomer cannot read a word of what was said before '
              'they arrived.',
              title: 'What they will and will not see',
            ),
            const SizedBox(height: Metrics.pad),
            // Handing over what was said before they arrived.
            //
            // Forward secrecy means a newcomer cannot read any of it, and that
            // is a promise rather than a gap. So there is nothing the group can
            // give them: there is only what one person has on their device and
            // chooses to pass on. People do this anyway with screenshots, and
            // then the group learns nothing.
            RxButton('Share the earlier messages',
                icon: Icons.history,
                weight: Weight.secondary,
                wide: true,
                onTap: () async {
                  final sent = rotelyx.handOverHistory();
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(sent == null
                        ? 'There is nothing here to share yet'
                        : 'Shared $sent messages. Everybody here was told.'),
                  ));
                }),
            const SizedBox(height: 8),
            Text(
              'Your copy, sent to everybody here, so the people who spoke know '
              'it happened. They cannot read any of it otherwise: nobody keeps '
              'the keys to what was said before somebody joined.',
              style: Type.small.copyWith(color: t.faint),
            ),
            const SizedBox(height: Metrics.pad),
            RxButton('Close',
                weight: Weight.secondary,
                wide: true,
                onTap: () => Navigator.pop(context)),
          ],
        ),
      ),
      ),
    );
  }

  /// Stop, and explain what changed and what to do about it.
  Future<void> _numberChanged() async {
    final t = RotelyxThemeScope.of(context);
    final current = rotelyx.safetyNumber ?? '';

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: t.surface,
        title: const Text('The safety number changed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'You compared this number before and it is different now. That '
              'happens when somebody adds a device to this conversation, and it '
              'also happens when somebody has placed themselves in the middle '
              'of it. Nothing here can tell those apart.',
            ),
            const SizedBox(height: Metrics.pad),
            const Text('Read this out to them before you send anything else:'),
            const SizedBox(height: 6),
            SelectableText(current, style: Type.numeric.copyWith(color: t.text)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('It matches, carry on'),
          ),
        ],
      ),
    );

    if (accepted == true && mounted) {
      store.acceptChangedNumber(widget.conversationId, current);
      setState(() => _conversation = store.load(widget.conversationId));
    }
  }

  /// Put the digits in front of them once, before the first message leaves.
  ///
  /// This does not refuse. Whichever they answer, the message is sent: the
  /// point is that nobody reaches their second message without having been told
  /// the number exists and been given the chance to compare it. Declining is
  /// recorded so the question does not come back, and the conversation goes on
  /// reading as unverified everywhere it is shown.
  Future<void> _askToCompare(String pending) async {
    final t = RotelyxThemeScope.of(context);
    final current = rotelyx.safetyNumber ?? '';

    final compared = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: t.surface,
        title: const Text('Have you compared this number?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Read these digits out to them on a call, or hold the two phones '
              'side by side. The same number on both means nobody is sitting in '
              'the middle of this conversation.',
            ),
            const SizedBox(height: Metrics.pad),
            SelectableText(current, style: Type.numeric.copyWith(color: t.text)),
            const SizedBox(height: Metrics.pad),
            Text(
              'Comparing it here proves nothing. That is the one channel '
              'somebody in the middle would control.',
              style: Type.small.copyWith(color: t.faint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now, send it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('I compared it, it matches'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (compared == true) {
      store.markVerified(widget.conversationId, current);
    } else {
      store.markAskedToVerify(widget.conversationId);
    }
    setState(() => _conversation = store.load(widget.conversationId));

    // Asked and answered: the send that triggered this now runs to the end.
    if (_input.text.trim() == pending) _send();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    // A picture on its own is a message; a picture with a line is one message
    // too. Only an empty composer with nothing waiting is nothing to send.
    if (text.isEmpty && _waiting == null) return;

    if (!_live) {
      // Not connected is a thing to fix, not a thing to announce. The session
      // is sealed on this device, so it can be rebuilt here and now, and the
      // socket can be reopened; a snackbar saying "not connected" left the
      // person with a message typed and nothing to do about it.
      rotelyx.wake();
      await _resumeIfNeeded();
      if (!mounted) return;
      if (!_live) {
        rotelyx.notice('Not connected yet. Trying again.');
        return;
      }
    }

    // Two states hold a message back, and they hold it back differently.
    //
    // `changed` refuses. The number now moves when a member or a device is
    // added, so the case being caught is a device added quietly to a
    // conversation somebody already trusted, and that is worth a refusal.
    //
    // `never` asks, once, with the digits on screen, and sends either way. The
    // reason it asks at all is that the shield in the header used to be the only
    // thing that knew this conversation was unverified, and it was behind a tap.
    // The reason it only asks once is that a question which returns on every
    // cold open is answered without being read by the third time, which is how
    // a real warning gets spent before it is needed.
    final state =
        store.verificationOf(widget.conversationId, rotelyx.safetyNumber);
    if (state == Verification.changed) {
      _numberChanged();
      return;
    }
    // Asked once, and only where it is the check that matters: a
    // conversation of two, at first contact, where the phrase could have been
    // answered by somebody else. In a group every member was let in by two
    // members who were already there, and asking somebody to read thirty
    // digits to eight people reads as absurd because it is. The number stays
    // in the panel for anybody who wants it.
    if (state == Verification.never &&
        rotelyx.safetyNumber != null &&
        rotelyx.memberCount <= 2) {
      _askToCompare(text);
      return;
    }

    // The picture waiting in the composer, with whatever was typed as its
    // caption, in one message.
    final waiting = _waiting;
    if (waiting != null) {
      _sendAttachment(Attachment(
        name: waiting.name,
        mime: waiting.mime,
        bytes: waiting.bytes,
        caption: text,
      ));
      _input.clear();
      setState(() {
        _waiting = null;
        _replyingTo = null;
      });
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
            // What it is, when what it is is not words: "Picture", or the
            // line that came with the picture. The alternative is the first
            // hundred characters of base64 in the quote, on their phone and on
            // ours, which is what it used to be.
            excerpt: attachmentGlimpse(Quoted.plain(answering.text)) ??
                Quoted.plain(answering.text),
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

  /// Place a call in this conversation.
  Future<void> _placeCall() async {
    final c = _conversation;
    if (c == null) return;

    // The microphone, before the system asks for it. A messenger asking for a
    // microphone is a reasonable thing to hesitate over, and the system prompt
    // gives nothing to weigh.
    final ready = await explainPermission(
      context,
      icon: Icons.mic_none_outlined,
      title: 'Calling ${c.displayTitle}',
      body: 'The microphone is used while a call is running and at no other '
          'time. Audio goes straight into the call encrypted and is never '
          'written to this phone or sent anywhere else.\n\n'
          'The call is carried through a relay on purpose, so the other person '
          'never learns your address.',
      allow: 'Start the call',
    );
    if (!ready || !mounted) return;

    final refused = await calls.place(c);
    if (refused == null || !mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(refused)));
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
          // Room for the navigation bar underneath.
        //
        // A bottom sheet is drawn against the bottom of the window, and on a
        // phone that draws edge to edge the bottom of the window is behind the
        // system's own buttons. So the last control on each of these sat under
        // them: visible, and not reachable.
        padding: EdgeInsets.fromLTRB(
          Metrics.wide,
          Metrics.wide,
          Metrics.wide,
          Metrics.wide + MediaQuery.viewPaddingOf(context).bottom,
        ),
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

  /// What a long press offers.
  ///
  /// Reactions first, because that is what a long press mostly means now, and
  /// the rest under them. Everything here acts on one message and everything
  /// here is reversible except the last, which asks.
  /// The reasons a message can be reported for.
  ///
  /// A list rather than a box to type in. A free text field inside a report
  /// is a place to put abuse of its own, it arrives in a language whoever
  /// reads it may not have, and a reason nobody reads is worth less than one
  /// that can be counted.
  static const _reportReasons = [
    'Spam',
    'Abuse or harassment',
    'Content involving a child',
    'Something else',
  ];

  /// Report somebody else's message.
  ///
  /// # Where it goes, and why not to us
  ///
  /// To the conversation. Nobody outside one can read a word of it, including
  /// whoever publishes this application, so a report that reached us would be
  /// a report about something we cannot see, and acting on it would mean
  /// being able to read what we say we cannot. The people who can already
  /// read it are the other members, and the ones who can act are whoever
  /// administers it: removing somebody is a commit, and they are the ones who
  /// can make it.
  ///
  /// SimpleX answers the same App Store requirement the same way and says so
  /// plainly: reports are private to the group and are not sent to the
  /// operator.
  ///
  /// # Why the screen says who will see it
  ///
  /// Everybody will. An application message is sealed for the group and a
  /// group is the only address MLS has, so there is no sending this to two
  /// members out of six. Somebody who believed a report was private and finds
  /// out it was not is worse off than somebody who never sent one.
  ///
  /// In a conversation of two there is nobody to tell except the person being
  /// reported, so there it offers blocking instead, which is the thing that
  /// actually helps.
  Future<void> _report(StoredMessage message) async {
    final t = RotelyxThemeScope.of(context);
    final alone = rotelyx.members.length <= 2;

    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Metrics.radius)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(Metrics.wide, Metrics.wide, Metrics.wide,
              Metrics.wide + MediaQuery.viewPaddingOf(context).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Report this message',
                  style: Type.title.copyWith(color: t.text)),
              const SizedBox(height: Metrics.gap),
              Text(
                alone
                    ? 'There is nobody in this conversation but the two of '
                        'you, so a report has nobody to go to. Blocking them '
                        'is what stops it, and it is immediate.'
                    : 'This goes to everybody in this conversation, including '
                        'the person you are reporting. Whoever can admit and '
                        'remove members is who can act on it.',
                style: Type.body.copyWith(color: t.muted),
              ),
              const SizedBox(height: Metrics.pad),
              if (!alone)
                for (final why in _reportReasons) ...[
                  RxButton(why,
                      weight: Weight.secondary,
                      wide: true,
                      onTap: () => Navigator.of(sheet).pop(why)),
                  const SizedBox(height: Metrics.gap),
                ],
              const RxNote(
                'Nobody outside this conversation can read a word of it, and '
                'that includes us. A report we could act on would be a '
                'conversation we could read.',
                title: 'Why it does not come to Rotelyx',
              ),
            ],
          ),
        ),
      ),
    );

    if (reason == null || !mounted) return;

    final sent = rotelyx.report(message.at, reason);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent
          ? 'Reported. Everybody here can see it.'
          : 'That could not be sent: ${rotelyx.lastError ?? "not connected"}'),
    ));
  }

  Future<void> _messageActions(StoredMessage message) async {
    final t = RotelyxThemeScope.of(context);
    final body = Ephemeral.plain(Quoted.plain(message.text));

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!message.mine)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Metrics.pad, vertical: Metrics.pad),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final emoji in _offered)
                      InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(_react(message, emoji));
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child:
                              Text(emoji, style: const TextStyle(fontSize: 26)),
                        ),
                      ),
                  ],
                ),
              ),
            ListTile(
              leading: Icon(Icons.reply, size: 20, color: t.muted),
              title: Text('Reply', style: Type.body.copyWith(color: t.text)),
              onTap: () {
                Navigator.of(sheet).pop();
                _replyTo(message);
              },
            ),
            if (body.isNotEmpty)
              ListTile(
                leading: Icon(Icons.copy_outlined, size: 20, color: t.muted),
                title: Text('Copy', style: Type.body.copyWith(color: t.text)),
                onTap: () {
                  Navigator.of(sheet).pop();
                  Clipboard.setData(ClipboardData(text: body));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
              ),
            if (message.mine && body.isNotEmpty)
              ListTile(
                leading: Icon(Icons.edit_outlined, size: 20, color: t.muted),
                title: Text('Edit', style: Type.body.copyWith(color: t.text)),
                subtitle: Text('The old text is not kept anywhere',
                    style: Type.small.copyWith(color: t.faint)),
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_edit(message, body));
                },
              ),
            if (body.isNotEmpty)
              ListTile(
                leading: Icon(Icons.forward_outlined, size: 20, color: t.muted),
                title: Text('Forward', style: Type.body.copyWith(color: t.text)),
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_forward(body));
                },
              ),
            // Reporting, which is for what somebody else sent.
            //
            // Offered on anybody else's message and not on your own, because
            // reporting yourself is not a thing anybody means to do.
            if (!message.mine)
              ListTile(
                leading: Icon(Icons.flag_outlined, size: 20, color: t.muted),
                title:
                    Text('Report', style: Type.body.copyWith(color: t.text)),
                subtitle: Text(
                    rotelyx.members.length > 2
                        ? 'Tells everybody in this conversation'
                        : 'There is nobody here but the two of you',
                    style: Type.small.copyWith(color: t.faint)),
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_report(message));
                },
              ),
            if (message.mine)
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    size: 20, color: Color(0xFFE0574A)),
                title: Text('Delete for everyone',
                    style: Type.body.copyWith(color: const Color(0xFFE0574A))),
                subtitle: Text(
                    'Asks their device to remove it. A modified client keeps it',
                    style: Type.small.copyWith(color: t.faint)),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _withdraw(message);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Change one of ours, on both sides.
  Future<void> _edit(StoredMessage message, String body) async {
    final t = RotelyxThemeScope.of(context);
    final field = TextEditingController(text: body);

    final changed = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: t.surface,
      isScrollControlled: true,
      // Grows to the height of the screen, so without this it grows past the
      // status bar and the first line is drawn behind the clock.
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: Metrics.gap,
            right: Metrics.gap,
            top: Metrics.gap,
            bottom: MediaQuery.of(sheet).viewInsets.bottom + Metrics.gap,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Edit', style: Type.title.copyWith(color: t.text)),
              const SizedBox(height: 6),
              Text(
                'The old text is replaced rather than kept, so nothing holds '
                'what you said before. The bubble is marked as edited.',
                style: Type.small.copyWith(color: t.faint),
              ),
              const SizedBox(height: Metrics.gap),
              TextField(
                controller: field,
                autofocus: true,
                maxLines: null,
                style: Type.body.copyWith(color: t.text),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: t.raised,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Metrics.radius),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.all(14),
                ),
              ),
              const SizedBox(height: Metrics.gap),
              RxButton('Save',
                  onTap: () => Navigator.of(sheet).pop(field.text.trim())),
            ],
          ),
        ),
      ),
    );

    field.dispose();
    if (changed == null || changed.isEmpty || changed == body) return;
    if (!rotelyx.edit(message, changed)) return;

    if (!mounted) return;
    setState(() => _conversation = store.load(widget.conversationId));
    widget.onChanged?.call();
  }

  /// Send this text to another conversation.
  ///
  /// Sent rather than relayed: the message is composed fresh in the other
  /// conversation, under that conversation's own keys. Nothing about where it
  /// came from travels with it, which is the point. A forward that carried its
  /// origin would tell the recipient who else you talk to.
  Future<void> _forward(String body) async {
    final t = RotelyxThemeScope.of(context);
    final elsewhere = store
        .loadAll()
        .where((c) => c.id != widget.conversationId)
        .toList();

    if (elsewhere.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There is nowhere else to send it')),
      );
      return;
    }

    final chosen = await showModalBottomSheet<StoredConversation>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(Metrics.gap),
              child: Text('Forward to',
                  style: Type.title.copyWith(color: t.text)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in elsewhere)
                    ListTile(
                      leading: RxAvatar(c.displayTitle, size: 34),
                      title: Text(c.displayTitle,
                          style: Type.body.copyWith(color: t.text)),
                      // A locked conversation is not offered. Sending into one
                      // would mean opening it, and forwarding is not a reason
                      // to take a lock off.
                      enabled: !store.isLocked(c.id),
                      subtitle: store.isLocked(c.id)
                          ? Text('Locked',
                              style: Type.small.copyWith(color: t.faint))
                          : null,
                      onTap: () => Navigator.of(sheet).pop(c),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (chosen == null || !mounted) return;

    // The other conversation has to be the live session to send into it.
    if (rotelyx.conversationId != chosen.id) {
      final resumed = await rotelyx.resume(chosen.id);
      if (!resumed) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${chosen.displayTitle} could not be reopened')),
        );
        return;
      }
    }

    final sent = rotelyx.send(body);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(sent
            ? 'Sent to ${chosen.displayTitle}'
            : 'That conversation is not connected')));

    // Back to where we were, or the next message typed here goes there.
    if (rotelyx.conversationId != widget.conversationId) {
      await rotelyx.resume(widget.conversationId);
    }
  }

  /// Withdraw one of ours from both sides.
  void _withdraw(StoredMessage message) {
    if (!rotelyx.retract(message)) return;

    final c = _conversation;
    if (c == null) return;

    setState(() {
      c.messages.removeWhere(
          (m) => m.mine && m.at.isAtSameMomentAs(message.at));
      _conversation = store.load(c.id) ?? c;
    });
    widget.onChanged?.call();
  }

  Future<void> _react(StoredMessage message, String chosen) async {
    final mine = message.reactions.entries
        .where((e) => e.value.contains(rotelyx.displayName))
        .map((e) => e.key)
        .toSet();

    // Tapping one already sent takes it back, which is the only way to remove
    // one and the behaviour every person tries first.
    final removing = mine.contains(chosen);
    if (!rotelyx.react(at: message.at, emoji: chosen, remove: removing)) return;

    // Shown here as well as sent, because the other side's copy is what the
    // signal changes and ours has to be changed by us.
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

      if (!mounted) return;
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
      c.forget(message.at);
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

  /// Whether this conversation is locked and has not been opened this run.
  bool _shut = false;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    // Before anything is loaded, let alone drawn. A locked conversation that
    // showed its last message while asking for a PIN would have already given
    // away the thing the PIN is for.
    if (_shut) {
      return _Shut(
        onOpened: () => setState(() {
          _shut = false;
          _conversation = store.load(widget.conversationId);
        }),
        conversationId: widget.conversationId,
        onBack: widget.onBack,
      );
    }

    final c = _conversation;

    if (c == null) {
      return Container(
        decoration: groundOf(t.backdrop),
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
      onBack: widget.swipeToClose ? widget.onBack : null,
      child: Container(
      decoration: groundOf(t.backdrop),
      // Not at the bottom, which the composer takes care of itself.
      //
      // Inset here, the composer stopped where the safe area did and the strip
      // below it was bare backdrop: a bar floating above a gap rather than the
      // bottom of the screen. The composer now runs to the edge and carries
      // the inset inside its own surface, which is what every bar that sits
      // at the bottom of a phone does.
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              key: const ValueKey('header'),
              live: _live,
              behind: rotelyx.isBehind(widget.conversationId),
              // The way back in, when this copy has fallen behind and kept the
              // invitation it came through. Going through it again is a
              // welcome into the same group, and the pairing screen lands it
              // in this row. Null for a host, which was never a guest.
              onRejoin: c.joinedVia == null
                  ? null
                  : () {
                      final via = c.joinedVia!;
                      widget.onBack?.call();
                      openLinkAgain(via);
                    },
              onCall: calls.isPossible ? _placeCall : null,
              onOpenContact: () => ContactSheet.open(
                context,
                widget.conversationId,
                onChanged: () {
                  setState(() =>
                      _conversation = store.load(widget.conversationId));
                  widget.onChanged?.call();
                },
              ),
              title: c.displayTitle,
              face: c.face,
              onBack: widget.onBack,
              onToggleSafety: () => setState(() => _showSafety = !_showSafety),
              onAddMember: _addMember,
              onCatchUp: () {
                if (rotelyx.askToCatchUp()) {
                  rotelyx.notice('Asked the others for what this device missed.');
                } else {
                  rotelyx.notice('Not connected. Try again in a moment.');
                }
              },
              expanded: _showSafety,
              verification: store.verificationOf(
                  widget.conversationId, rotelyx.safetyNumber),
              resuming: _resuming,
              resumable: store.sessionBlob(widget.conversationId) != null,
            ),
            AnimatedSize(
              key: const ValueKey('safety'),
              duration: Motion.sheet,
              curve: Motion.sheetCurve,
              alignment: Alignment.topCenter,
              child: _showSafety
                  ? _SafetyPanel(conversationId: widget.conversationId)
                  : const SizedBox(width: double.infinity),
            ),
            if (!_resuming &&
                !_live &&
                store.sessionBlob(widget.conversationId) == null)
              const Padding(
                key: ValueKey('unreachable'),
                padding: EdgeInsets.fromLTRB(
                    Metrics.pad, Metrics.pad, Metrics.pad, 0),
                child: RxNote(
                  'This transcript is on the device, but the group state was '
                  'never sealed, so there is nothing to rejoin. Pair again with '
                  'the same person to start a new conversation.',
                  title: 'Readable, not reachable',
                ),
              ),
            // A call already happening in here, said on the way in.
            //
            // There is no way to be told about a call in a conversation that is
            // not open without listening at every conversation's address at
            // once, and doing that from one connection tells the mailbox that
            // those conversations belong to one device. That was built, it
            // broke exactly the separation this application exists for, and it
            // was taken out again.
            //
            // So this is the honest half: nothing is listened to, and the room
            // is there to walk into the moment somebody opens the door.
            if (rotelyx.callIsLiveIn(widget.conversationId))
              Padding(
                key: const ValueKey('call'),
                padding: const EdgeInsets.fromLTRB(
                    Metrics.pad, 0, Metrics.pad, Metrics.pad),
                child: Material(
                  color: Tone.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: calls.isPossible ? _placeCall : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          Icon(Icons.podcasts, size: 16, color: Tone.accent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('A call is happening here',
                                style: Type.body.copyWith(color: t.text)),
                          ),
                          Text('Join',
                              style: Type.label.copyWith(
                                  color: Tone.accent, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // Somebody wants to let a person in, and it does not happen
            // until a member who is not the one asking agrees.
            //
            // A banner rather than a line in the transcript, because this is
            // a decision with a deadline: the person is waiting at a meeting
            // place, and a request scrolled past is a person who never gets
            // in. Once it is done it becomes a line like any other arrival.
            if (_notice != null)
              _Notice(
                key: const ValueKey('notice'),
                text: _notice!,
                onDismiss: () {
                  _noticeTimer?.cancel();
                  setState(() => _notice = null);
                },
              ),

            if (rotelyx.pendingAddition != null)
              _AdmissionRequest(
                key: const ValueKey('admission'),
                waiting: rotelyx.pendingAddition!,
                onLetIn: () {
                  if (rotelyx.confirmPendingAddition()) setState(() {});
                },
                onNotNow: () {
                  rotelyx.dismissPendingAddition();
                  setState(() {});
                },
              ),

            // Keyed, and every sibling above it keyed too.
            //
            // # Why this one key matters more than the rest
            //
            // A `Column` matches its children to the previous build by
            // position. The banners above this one come and go -- a notice, a
            // request to admit somebody, the note about a conversation that
            // cannot be rejoined, which appears and disappears as the live
            // conversation moves between rooms -- and every one of those
            // insertions shifted this list down a slot. Flutter then found a
            // different widget where the list used to be, threw the whole
            // transcript away and built it again: every bubble a new element,
            // every entry animation played from nothing, every picture decoded
            // afresh.
            //
            // That is the flash of the whole conversation vanishing and coming
            // back, and it is the fault he reported five times. Keys let the
            // column recognise its children wherever they end up, so a banner
            // appearing costs a banner and nothing else.
            // Taken here rather than in `initState`: the messages that were
            // waiting arrive after the screen is up, so where to open is only
            // knowable once they are in the transcript.
            Builder(builder: (_) {
              _openWhereReadingStopped(c);
              return const SizedBox.shrink();
            }),
            Expanded(
              key: const ValueKey('transcript'),
              child: Stack(
                children: [
                  GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusScope.of(context).unfocus(),
                child: c.messages.isEmpty
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // Kept although `app.dart` now does this for every
                      // screen: the empty transcript is a large target and an
                      // opaque one here means the tap does not have to travel
                      // to the root to be understood.
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
                      // Built from the newest message upwards, so offset zero
                      // is the bottom of the conversation and that is where
                      // it opens, every time, before anything above it has
                      // been laid out. It used to be built top down and
                      // opened wherever the first frame's estimate of the
                      // height put it, which for a long conversation with
                      // pictures in it was somewhere in the middle.
                      reverse: true,
                      itemCount: c.messages.length,

                      // Where a bubble went, so the list can move it instead of
                      // building it again.
                      //
                      // # The whole reason this callback exists here
                      //
                      // The list is built newest first, so the message that
                      // just arrived is row zero and every older message moves
                      // down one. A lazy list matches its children to rows by
                      // position, so after one arrival every row holds a
                      // different message from the one before: Flutter throws
                      // away every element on the screen and builds the
                      // transcript again, pictures decoded from scratch and
                      // all. That is the flash of the whole conversation
                      // disappearing and coming back that he reported four
                      // times, and neither the keys nor the throttling fixed
                      // it, because the problem is not what is rebuilt but
                      // that the rows are found by position at all.
                      //
                      // With this, the list asks "the bubble for that message
                      // -- which row is it now?", finds it one row further
                      // down, and moves the element it already has.
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<DateTime>) return null;
                        final at = key.value.millisecondsSinceEpoch;
                        for (var i = c.messages.length - 1; i >= 0; i--) {
                          if (c.messages[i].at.millisecondsSinceEpoch == at) {
                            return c.messages.length - 1 - i;
                          }
                        }
                        return null;
                      },
                      itemBuilder: (_, ri) {
                        final i = c.messages.length - 1 - ri;
                        final message = c.messages[i];

                        // A control message that was written down before this
                        // build knew what it was.
                        //
                        // Nothing writes these any more: an unknown one is
                        // dropped where it arrives. But the ones already in
                        // somebody's conversation are still there, and one of
                        // them is a group picture, which is forty thousand
                        // characters of base64 sitting in the transcript. They
                        // are not shown rather than deleted, because deleting
                        // somebody's transcript to tidy up is not this
                        // screen's to do.
                        if (Signal.isControl(message.text)) {
                          return SizedBox.shrink(key: ValueKey(message.at));
                        }

                        // A call is not something somebody said, so it is not
                        // drawn as something somebody said. No bubble, no side,
                        // no reply and no reaction: those all belong to a
                        // message with an author, and this has an event.
                        if (message.call != null) {
                          return _CallLine(
                              key: ValueKey(message.at), message: message);
                        }

                        final bubble = _Bubble(
                          key: message.at == _targetAt
                              ? _target
                              : ValueKey(message.at),
                          message: message,
                          // Marked for a moment after a jump landed on it.
                          found: _flash != null && _flash == message.at,
                          // Tapping the quote goes to what is being answered,
                          // whatever it is: a sentence, a picture, a link.
                          onOpenQuoted: (quoted) =>
                              _goToQuoted(c.messages, i, quoted),
                          showAuthor: _startsRun(c.messages, i),
                          // The author's own face when it has arrived; in a
                          // conversation of two, theirs; in a group with no
                          // face for this author, their initial in their
                          // colour rather than somebody else's picture.
                          // Ours for our own, theirs for theirs: the same
                          // picture Settings shows, so a group has every
                          // member's face in it including the reader's.
                          face: message.mine
                              ? store.myPicture
                              : (c.faceOf(message.author) ??
                                  (_isGroup(c) ? null : c.picture)),
                          faceName: message.mine
                              ? rotelyx.displayName
                              : (message.author.isNotEmpty
                                  ? message.author
                                  : c.displayTitle),
                          // In a group, whose bubble this is. Their name on
                          // the first of a run and their colour on every one
                          // of them: eight people in the same grey bubble
                          // read as one person talking to themselves.
                          authorTint: _isGroup(c) &&
                                  message.author.isNotEmpty &&
                                  message.author != c.title
                              ? message.author
                              : null,
                          // And which side they speak from. Taken from the
                          // order the group spoke in rather than from a hash
                          // of the names: a hash puts everybody on the same
                          // side often enough that it looked broken, which is
                          // what it was.
                          authorRight: _isGroup(c) && _sides.rightFor(c, i),
                          inGroup: _isGroup(c),
                          onReply: () => _replyTo(message),
                          // Applied inside `_Bubble`, around the bubble alone.
                          // Wrapping this row put the fire across the whole
                          // width of the conversation with the bubble sitting
                          // untouched beneath it.
                          burning: _burning.contains(message.at),
                          onGone: () => _gone(message),
                          onReact: () => _messageActions(message),
                        );

                        // Decided once per message, never per build.
                        //
                        // # The hole this caused
                        //
                        // The rule below was evaluated on every rebuild, and
                        // two of its terms change with time: whether the
                        // conversation has settled, and which message is the
                        // newest. So the last bubble was drawn plainly for a
                        // second and a half and then, on the next rebuild,
                        // wrapped in an entrance -- which makes it a different
                        // widget, so Flutter builds a new element, and an
                        // entrance starts at nothing. The newest message
                        // vanished and faded back in, leaving a bubble-shaped
                        // hole above the composer while older messages loaded.
                        // He described it exactly: "a gap where the last
                        // message should be".
                        //
                        // Now the decision is made the first time a message is
                        // drawn and written down, so its shape never changes
                        // underneath it.
                        //
                        // Only the newest message animates in, and only once
                        // the conversation has settled.
                        //
                        // # Why the two conditions
                        //
                        // Opening a conversation collects whatever arrived
                        // while it was closed: thirty messages in a couple of
                        // seconds, every one of them newer than the moment the
                        // screen opened, so every one was wrapped in an
                        // entrance that starts at nothing. Thirty bubbles
                        // fading in at once, several times as the backlog
                        // lands, is the whole conversation blinking -- which is
                        // exactly what he described: it happens *on entering* a
                        // room that has messages waiting.
                        //
                        // A settling period covers the backlog, and animating
                        // only the last bubble covers a burst: what a person
                        // should see is the newest line arriving, not the
                        // transcript reassembling itself.
                        final stamp = message.at.millisecondsSinceEpoch;
                        if (!_drawn.contains(stamp)) {
                          _drawn.add(stamp);
                          final newest = i == c.messages.length - 1;
                          final settled = DateTime.now()
                                  .difference(_openedAt)
                                  .inMilliseconds >
                              1500;
                          if (newest && settled && message.at.isAfter(_openedAt)) {
                            _entering.add(stamp);
                          }
                        }

                        final shown = _entering.contains(stamp)
                            ? RxEnter(key: ValueKey(message.at), child: bubble)
                            : bubble;

                        // "You stopped here." Above the first message that
                        // arrived after the last time this conversation was
                        // open, and nowhere else.
                        if (stamp != _unreadMark(c)) return shown;
                        return Column(
                          key: ValueKey('unread-$stamp'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
                              child: Row(
                                children: [
                                  Expanded(
                                      child: WavyRule(
                                          colour: Tone.accent
                                              .withValues(alpha: 0.55))),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Text('unread',
                                        style: Type.small.copyWith(
                                            fontSize: 11,
                                            letterSpacing: 0.6,
                                            color: Tone.accent)),
                                  ),
                                  Expanded(
                                      child: WavyRule(
                                          colour: Tone.accent
                                              .withValues(alpha: 0.55))),
                                ],
                              ),
                            ),
                            shown,
                          ],
                        );
                      },
                    ),
              ),

                  // The way back down, while there is a way down to go.
                  //
                  // Reading something from an hour ago in a group that is
                  // still talking leaves the newest message somewhere below
                  // the screen, and the only way back was to drag. It appears
                  // when the bottom is more than a screen away and goes when
                  // it is not, so it is never in front of anything while the
                  // conversation is being read at the bottom, which is where
                  // it is read most of the time.
                  Positioned(
                    right: 14,
                    bottom: 14,
                    child: IgnorePointer(
                      ignoring: !_away,
                      child: AnimatedOpacity(
                        opacity: _away ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: AnimatedSlide(
                          offset: _away ? Offset.zero : const Offset(0, 0.3),
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOut,
                          child: _ToTheEnd(
                            waiting: _below,
                            onTap: () {
                              _toBottom();
                              HapticFeedback.selectionClick();
                              setState(() => _below = 0);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // What is about to be sent, above the field it will be sent with.
            if (_waiting != null)
              _WaitingPicture(
                key: const ValueKey('waiting'),
                file: _waiting!,
                onCancel: () => setState(() => _waiting = null),
              ),
            if (_replyingTo != null)
              _ReplyingTo(
                key: const ValueKey('replying'),
                message: _replyingTo!,
                fallbackAuthor: c.title,
                onCancel: () => setState(() => _replyingTo = null),
              ),
            _Composer(
              key: const ValueKey('composer'),
              controller: _input,
              focus: _focus,
              onSend: _send,
              onAttach: _attach,
              conversationId: widget.conversationId,
              onInspect: () => setState(() => _showSafety = !_showSafety),
              onPicture: _sendPicture,
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
      i == 0 ||
      all[i - 1].mine != all[i].mine ||
      all[i - 1].author != all[i].author;

  /// More than two in it, as far as this device can tell: from the live
  /// session when this is the live conversation, otherwise from whether the
  /// messages come from more than one author.
  bool _isGroup(StoredConversation c) {
    if (rotelyx.conversationId == c.id && rotelyx.memberCount > 0) {
      return rotelyx.memberCount > 2;
    }
    if (c.groupName.isNotEmpty || c.groupPicture != null) return true;
    final authors = <String>{};
    for (final m in c.messages) {
      if (!m.mine && m.author.isNotEmpty) authors.add(m.author);
      if (authors.length > 1) return true;
    }
    return false;
  }
}

class _Header extends StatelessWidget {
  const _Header({
    super.key,
    required this.title,
    required this.face,
    required this.onOpenContact,
    required this.onCall,
    required this.onBack,
    required this.onToggleSafety,
    required this.onAddMember,
    required this.onCatchUp,
    required this.expanded,
    required this.verification,
    required this.resuming,
    required this.resumable,
    required this.live,
    required this.behind,
    this.onRejoin,
  });

  final String title;

  /// Whether this device has fallen behind the group and cannot read it.
  final bool behind;

  /// Rejoin the group through the invitation this device joined by, offered
  /// on the chip that says it has fallen behind. See `StoredConversation.joinedVia`.
  final VoidCallback? onRejoin;

  /// Their picture, when they have sent one. The list and every bubble
  /// already drew it; the header drew their initial, so the one place that
  /// names the conversation was the one place they did not look like
  /// themselves.
  final Uint8List? face;

  /// Their name, their picture, and what this device does about them.
  final VoidCallback onOpenContact;

  /// Place a call. Null when this build cannot: a button that explains itself
  /// after being pressed is worse than one that was never there.
  final VoidCallback? onCall;

  final VoidCallback? onBack;
  final VoidCallback onToggleSafety;
  final VoidCallback onAddMember;
  final VoidCallback onCatchUp;
  final bool expanded;

  /// What the shield reports. It used to report whether the panel below it was
  /// open, which is the one thing a person looking at a shield is not asking.
  final Verification verification;
  final bool resuming;

  /// Joined, and joined to the conversation this header sits above. Passed in
  /// rather than read from the service, which cannot tell which conversation
  /// this is.
  final bool live;

  /// Whether a sealed session exists to come back from. Without one the
  /// transcript is readable and the conversation is not resumable, the two are
  /// different failures and the header should not call both "not connected".
  final bool resumable;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

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
          face == null
              ? RxAvatar(title, size: 36)
              : ClipOval(
                  child: Image.memory(face!,
                      width: 36, height: 36, fit: BoxFit.cover)),
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
                    // What state the conversation is in, because it changes
                    // and somebody should not have to guess which one they got.
                    //
                    // It said `via mailbox` while it was working, which is the
                    // one state where naming the route buys nothing: everything
                    // goes through the mailbox, so it was a constant dressed up
                    // as information, and it was the piece of machinery talking
                    // rather than the conversation. The other three say what is
                    // happening, so this one does too.
                    // "Behind" outranks "connected", because it is the one
                    // state that looks like nothing being wrong. A device that
                    // cannot read a group any more is connected, at an epoch,
                    // with a roster -- and every message it is handed is noise.
                    // Saying `connected` there is the header lying.
                    // Behind, and with a way back: the chip is the way back.
                    // A red label that only names the problem leaves the
                    // person to work out that the fix is the link they were
                    // sent a week ago, and most will not.
                    GestureDetector(
                      onTap: behind ? onRejoin : null,
                      child: RxChip(
                          behind
                              ? (onRejoin != null
                                  ? 'behind this group, tap to rejoin'
                                  : 'behind this group')
                              : live
                                  ? 'connected'
                                  : resuming
                                      ? 'reconnecting'
                                      : resumable
                                          ? 'offline'
                                          : 'history only',
                          tone: behind
                              ? Tone.bad
                              : live
                                  ? Tone.good
                                  : resuming
                                      ? Tone.warn
                                      : t.faint,
                          icon: behind
                              ? Icons.link_off
                              : live
                                  ? Icons.inbox_outlined
                                  : resumable
                                      ? Icons.cloud_off
                                      : Icons.history),
                    ),
                    // The epoch used to sit here and pushed the row onto a
                    // second line on a phone, which made the header taller than
                    // the name it exists to show. It is a protocol detail and
                    // it now lives in the safety panel, next to the number it
                    // belongs with. The route stays, because it changes with
                    // circumstance and the user should not have to guess.
                    if (live && rotelyx.memberCount > 2)
                      RxChip('${rotelyx.memberCount} here',
                          icon: Icons.group_outlined),
                    // Which epoch this device is at. Every commit moves it,
                    // and two devices showing different numbers are two
                    // devices in different conversations, which is the one
                    // thing worth knowing when messages seem to go missing.
                    if (live && rotelyx.memberCount > 1)
                      RxChip('epoch ${rotelyx.epoch}',
                          icon: Icons.tag),
                  ],
                ),
              ],
            ),
          ),
          // One action and one menu, not four buttons.
          //
          // Four fixed width buttons beside an avatar leave about eighty
          // logical pixels for the name and the route chip on a 360dp phone,
          // and the chip is wider than that, so the state chip was painted over
          // the add-member button. It read as a spacing bug and was a row that
          // had run out of room. An iPhone is wider and hid it.
          //
          // Calling is the thing somebody opens a conversation to do, so it
          // keeps its place. The rest are settings and they belong behind one.
          if (onCall != null)
            IconButton(
              onPressed: onCall,
              tooltip: 'Call',
              icon: Icon(Icons.call, size: 19, color: t.muted),
            ),
          PopupMenuButton<_HeaderAction>(
            tooltip: 'More',
            position: PopupMenuPosition.under,
            // Tinted when the safety number changed, because that is a warning
            // and a warning behind a menu nobody opens is not one. The rest of
            // the states are answers to a question the person asked, and they
            // can wait until the menu is open.
            icon: Icon(
              Icons.more_vert,
              size: 20,
              color: verification == Verification.changed ? Tone.bad : t.muted,
            ),
            onSelected: (action) => switch (action) {
              _HeaderAction.addMember => onAddMember(),
              _HeaderAction.contact => onOpenContact(),
              _HeaderAction.safety => onToggleSafety(),
              _HeaderAction.catchUp => onCatchUp(),
            },
            itemBuilder: (_) => [
              // For a device that was off, or behind: ask the others for
              // what it missed. What they have is their copy; what this
              // device has let go of stays gone.
              if (live && rotelyx.memberCount > 1)
                const PopupMenuItem(
                  value: _HeaderAction.catchUp,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.history, size: 19),
                    title: Text('Catch up on what I missed'),
                  ),
                ),
              if (live && rotelyx.memberCount > 1)
                const PopupMenuItem(
                  value: _HeaderAction.addMember,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.person_add_alt, size: 19),
                    title: Text('Add someone'),
                  ),
                ),
              const PopupMenuItem(
                value: _HeaderAction.contact,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.tune, size: 19),
                  title: Text('Name, picture and notifications'),
                ),
              ),
              PopupMenuItem(
                value: _HeaderAction.safety,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    switch (verification) {
                      Verification.matches => Icons.verified_user,
                      Verification.changed => Icons.gpp_maybe,
                      _ => Icons.gpp_bad,
                    },
                    size: 19,
                    color: switch (verification) {
                      Verification.matches => Tone.good,
                      Verification.changed => Tone.bad,
                      _ => null,
                    },
                  ),
                  title: Text(switch (verification) {
                    Verification.matches => 'Safety number, compared',
                    Verification.changed => 'Safety number changed',
                    Verification.declined => 'Safety number, never compared',
                    Verification.never => 'Safety number, not compared yet',
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the header's overflow menu can do.
enum _HeaderAction { addMember, contact, safety, catchUp }

class _SafetyPanel extends StatefulWidget {
  const _SafetyPanel({required this.conversationId});
  final String conversationId;

  @override
  State<_SafetyPanel> createState() => _SafetyPanelState();
}

class _SafetyPanelState extends State<_SafetyPanel> {
  /// Ask, then remove.
  ///
  /// The dialog says the three things a person needs and no more: that
  /// everyone will see it, that it cannot be undone, and that it does not
  /// reach backwards. The last one matters most and is the one people assume
  /// wrongly: removing somebody does not unsay what they already read.
  Future<void> _confirmRemoval(String label, String key) async {
    final t = RotelyxThemeScope.of(context);

    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('Remove $label?'),
        content: const Text(
          'Everyone in the conversation sees this, including them, and there '
          'is no undo: to let them back in you would have to invite them '
          'again.\n\n'
          'From now on they cannot read anything. What they already received, '
          'they keep, and nothing here can change that.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove', style: TextStyle(color: Tone.bad)),
          ),
        ],
      ),
    );

    if (go != true || !mounted) return;

    final done = await rotelyx.removeMember(key);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(done
          ? '$label was removed.'
          : 'Could not remove $label: ${rotelyx.lastError ?? "unknown"}'),
    ));
    setState(() {});
  }

  /// What has been reported in this conversation and not yet dealt with.
  List<String> get _reports =>
      store.load(widget.conversationId)?.reports ?? const [];

  /// One stored report, as a sentence.
  ///
  /// The stored form is `when|reason|who`, three fields with the separator
  /// stripped out of each on the way in, so splitting is safe.
  static String _readReport(String row) {
    final parts = row.split('|');
    if (parts.length < 3) return row;

    final at = int.tryParse(parts[0]);
    final String when;
    if (at == null) {
      when = 'a message';
    } else {
      final sent = DateTime.fromMillisecondsSinceEpoch(at);
      when = 'the message from '
          '${sent.hour.toString().padLeft(2, '0')}:'
          '${sent.minute.toString().padLeft(2, '0')}';
    }
    final who = parts[2].isEmpty ? 'Somebody' : parts[2];
    return '$who reported $when: ${parts[1]}';
  }

  /// What one member can be done to.
  ///
  /// Blocking and removing are different acts and the sheet says so. Blocking
  /// is one person deciding what reaches their own phone: local, immediate,
  /// and nobody's business but theirs. Removing is a commit the whole group
  /// sees and cannot be undone, which is why it is still behind a long press
  /// and a second question.
  Future<void> _memberActions(String label, String key) async {
    final t = RotelyxThemeScope.of(context);
    final conversation = store.load(widget.conversationId);
    final isBlocked = conversation?.blocked.contains(key) ?? false;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Metrics.radius)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(Metrics.wide, Metrics.wide, Metrics.wide,
              Metrics.wide + MediaQuery.viewPaddingOf(context).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(label, style: Type.title.copyWith(color: t.text)),
              const SizedBox(height: Metrics.gap),
              Text(
                isBlocked
                    ? 'Nothing from them reaches this phone. They are not '
                        'told, and they are still in the conversation for '
                        'everybody else.'
                    : 'Blocking is yours alone. Nothing they send is written '
                        'down, counted or shown here from the next message '
                        'on. They are not told, and the others go on seeing '
                        'them.',
                style: Type.body.copyWith(color: t.muted),
              ),
              const SizedBox(height: Metrics.pad),
              RxButton(
                isBlocked ? 'Unblock them' : 'Block them',
                weight: isBlocked ? Weight.secondary : Weight.primary,
                icon: isBlocked
                    ? Icons.lock_open_outlined
                    : Icons.block_outlined,
                wide: true,
                onTap: () {
                  if (isBlocked) {
                    rotelyx.unblock(widget.conversationId, key);
                  } else {
                    rotelyx.block(widget.conversationId, key);
                  }
                  Navigator.of(sheet).pop();
                },
              ),
              const SizedBox(height: Metrics.gap),
              RxButton('Remove from the conversation',
                  weight: Weight.secondary,
                  icon: Icons.person_remove_outlined,
                  wide: true, onTap: () {
                Navigator.of(sheet).pop();
                _confirmRemoval(label, key);
              }),
              const SizedBox(height: Metrics.pad),
              const RxNote(
                'Removing is a commit every member sees and it cannot be '
                'undone. Blocking is not sent anywhere.',
                title: 'The difference',
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final number = rotelyx.safetyNumber;
    final state = store.verificationOf(widget.conversationId, number);

    return Container(
      width: double.infinity,
      // Capped and scrolled inside. The panel grows with the conversation:
      // one chip per member, and a group of fourteen makes it taller than the
      // screen, so everything under the first rows of chips was unreachable
      // and the transcript beneath it was squeezed to nothing. Not a fixed
      // height, because on a small phone half the screen is already a lot.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.46,
      ),
      padding: const EdgeInsets.all(Metrics.pad),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: SingleChildScrollView(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Safety number', style: Type.label.copyWith(color: t.muted)),
              const Spacer(),
              // Said plainly, in all three states. A conversation nobody has
              // compared should look different from one that has been, or the
              // comparison is a thing people believe they did.
              Text(
                switch (state) {
                  Verification.matches => 'compared',
                  Verification.changed => 'changed since you compared it',
                  Verification.declined => 'never compared',
                  Verification.never => 'not compared yet',
                },
                style: Type.small.copyWith(
                  color: switch (state) {
                    Verification.matches => Tone.good,
                    Verification.changed => Tone.bad,
                    _ => t.muted,
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(number ?? 'not ready yet',
              style: Type.numeric.copyWith(color: t.text)),
          const SizedBox(height: 8),
          if (number != null && state != Verification.matches) ...[
            RxButton(
              state == Verification.changed
                  ? 'It still matches, trust it again'
                  : 'I have compared it, and it matches',
              wide: true,
              weight: Weight.secondary,
              onTap: () {
                store.markVerified(widget.conversationId, number);
                setState(() {});
              },
            ),
            const SizedBox(height: 8),
          ],
          // What it is for comes before how to use it. The panel used to open
          // with the caveat, which only makes sense to somebody who already
          // knew why they were looking at a row of digits.
          Text(
            'This is how you know you are talking to the person you think you '
            'are. Read it out on a call, or hold the phones side by side. Same '
            'number on both means nobody is in between.',
            style: Type.small.copyWith(color: t.muted),
          ),
          const SizedBox(height: 6),
          Text(
            'Comparing it in this conversation proves nothing: that is the one '
            'channel somebody in the middle would control.',
            style: Type.small.copyWith(color: t.faint),
          ),
          if (rotelyx.roster.length > 1) ...[
            const SizedBox(height: Metrics.pad),
            Text('In this conversation',
                style: Type.label.copyWith(color: t.muted)),
            const SizedBox(height: 6),
            // Long-press to remove. It lives beside the safety number because
            // that is the panel somebody opens when they are worried, and
            // revoking a device is what they came to do. Not a visible button:
            // removal is a commit everyone sees and cannot be undone, so it
            // asks for a deliberate gesture and then asks again.
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in rotelyx.members)
                  GestureDetector(
                    onTap: () => _memberActions(m.label, m.key),
                    onLongPress: () => _confirmRemoval(m.label, m.key),
                    child: RxChip(
                      store.load(widget.conversationId)
                                  ?.blocked
                                  .contains(m.key) ==
                              true
                          ? '${m.label} (blocked)'
                          : m.label,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Tap a member to block them. Hold to remove them. These are '
              'labels each member chose: the group authenticates them, and '
              'nothing outside it does.',
              style: Type.small.copyWith(color: t.faint),
            ),
          ],

          // What somebody reported, for whoever can act on it.
          //
          // A report arrives while nobody is looking and the requirement it
          // answers is about acting rather than about being told, so it is
          // kept and shown here, beside the members and the button that
          // removes one.
          if (_reports.isNotEmpty) ...[
            const SizedBox(height: Metrics.pad),
            RxNote(
              _reports.map(_readReport).join('\n'),
              title: _reports.length == 1
                  ? 'Somebody reported a message'
                  : '${_reports.length} messages were reported',
              tone: Tone.warn,
            ),
            const SizedBox(height: Metrics.gap),
            RxButton('Mark these as dealt with',
                weight: Weight.secondary,
                wide: true, onTap: () {
              store.clearReports(widget.conversationId);
              setState(() {});
            }),
          ],

          // Who decides, in a conversation big enough for that to mean
          // anything. In a pair there is only the other person, and a switch
          // that says "only you and them may let people in" says nothing.
          if (rotelyx.members.length > 2) ...[
            const SizedBox(height: Metrics.pad),
            Text('Who can let people in',
                style: Type.label.copyWith(color: t.muted)),
            const SizedBox(height: 6),
            Text(
              rotelyx.adminRuleIsRunning
                  ? 'Only the members ticked below can turn a request into a '
                      'member. Anybody can still ask.'
                  : 'Anybody here can let somebody in, as long as a second '
                      'member agrees. Tick names to narrow that to them.',
              style: Type.small.copyWith(color: t.muted),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in rotelyx.members)
                  _DecidesChip(
                    label: m.label,
                    decides: rotelyx.admins.contains(m.label),
                    onTap: () async {
                      final next = rotelyx.admins.toList();
                      next.contains(m.label)
                          ? next.remove(m.label)
                          : next.add(m.label);
                      await rotelyx.setAdmins(next);
                      setState(() {});
                    },
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Changing this is a commit, so everybody sees it happen. If every '
              'ticked member leaves, the rule stands down rather than leaving '
              'a conversation that can never admit anybody again.',
              style: Type.small.copyWith(color: t.faint),
            ),
          ],
        ],
      ),
      ),
    );
  }
}

/// The button that takes the conversation back to its newest message.
///
/// In the application's own purple, small, and with a shadow rather than a
/// border: it floats over the transcript and has to be legible against a
/// bubble, a picture or the ground without being the loudest thing on the
/// screen.
class _ToTheEnd extends StatelessWidget {
  const _ToTheEnd({required this.onTap, this.waiting = 0});

  final VoidCallback onTap;

  /// How many arrived while the end was off the screen. Zero draws the plain
  /// circle; anything else draws the count beside the arrow, because "there is
  /// a way down" and "three people have said something" are different facts.
  final int waiting;

  @override
  Widget build(BuildContext context) {
    final shape = waiting > 0
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(19))
        : const CircleBorder();

    return Material(
      color: Tone.accent,
      shape: shape,
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: SizedBox(
          height: 38,
          child: waiting == 0
              ? const SizedBox(
                  width: 38,
                  child: Icon(Icons.keyboard_arrow_down,
                      color: Colors.white, size: 24),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.keyboard_arrow_down,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 5),
                      Text(
                          waiting == 1
                              ? '1 new message'
                              : '$waiting new messages',
                          style: Type.label
                              .copyWith(color: Colors.white, fontSize: 12.5)),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// A member, and whether this conversation lets them turn a request into a
/// member.
class _DecidesChip extends StatelessWidget {
  const _DecidesChip({
    required this.label,
    required this.decides,
    required this.onTap,
  });

  final String label;
  final bool decides;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: decides
              ? Tone.accent.withValues(alpha: 0.16)
              : t.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: decides
                ? Tone.accent.withValues(alpha: 0.45)
                : t.line.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              decides ? Icons.check_circle : Icons.circle_outlined,
              size: 13,
              color: decides ? Tone.accent : t.faint,
            ),
            const SizedBox(width: 6),
            Text(label,
                style: Type.small
                    .copyWith(color: decides ? t.text : t.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Which side of a group each message sits on.
///
/// Down the transcript the side flips every time the speaker changes: one
/// person's run of messages is on the left, the next person's on the right,
/// the next on the left again. A group then reads as a conversation between
/// people instead of as a column, which is the whole complaint.
///
/// Two earlier attempts are worth knowing about, because both looked correct
/// and neither was.
///
///   * A hash of the name. Stable, needs no state, and on a real group put six
///     of seven people down the same side: a hash is not a balanced two-way
///     split.
///   * A side per person, alternating in the order they first spoke. Balanced
///     over the whole group and still wrong on the screen: the people talking
///     in any one minute were the first, third and fifth to have spoken, so
///     every bubble in view was on the left again.
///
/// What a person actually sees is a sequence of turns, so it is the turn that
/// decides. Somebody's side can differ between two parts of the conversation,
/// which is why the name, the colour and the face are on the bubble: those say
/// who is talking, and the side says that the talking is going back and forth.
class _Sides {
  /// Which side a message sits on, by the moment it was written.
  ///
  /// By the message and never by its position in the list. Keyed by position,
  /// this was wrong every time the transcript changed shape: a message
  /// arriving, one burning, one being withdrawn, a handover inserting older
  /// messages. Every row after the change took the side that had belonged to
  /// its neighbour, so the whole conversation flipped left and right at once.
  /// That is the fast flicker he saw in groups and never in a conversation of
  /// two -- because a conversation of two has no sides to flip.
  final Map<int, bool> _right = {};

  String? _of;
  int _read = 0;

  bool rightFor(StoredConversation c, int index) {
    if (_of != c.id) {
      _right.clear();
      _read = 0;
      _of = c.id;
    }
    if (_read != c.messages.length) {
      _right.clear();
      String? last;
      var right = false;
      for (final m in c.messages) {
        // Ours is always on the right and is not a turn in this sense: a run
        // of theirs either side of something we said is still one run.
        if (m.mine || m.author.isEmpty) continue;
        if (last != null && m.author != last) right = !right;
        last = m.author;
        _right[m.at.millisecondsSinceEpoch] = right;
      }
      _read = c.messages.length;
    }
    if (index < 0 || index >= c.messages.length) return false;
    return _right[c.messages[index].at.millisecondsSinceEpoch] ?? false;
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.message,
    required this.showAuthor,
    this.authorTint,
    this.authorRight = false,
    this.inGroup = false,
    this.found = false,
    this.onOpenQuoted,
    this.onReply,
    this.burning = false,
    this.onGone,
    this.onReact,
    this.face,
    this.faceName = '',
  });

  final StoredMessage message;
  final bool showAuthor;

  /// Whose bubble this is, in a group: their name, which colours the bubble
  /// and is written above the first of each run. Null in a conversation of
  /// two, and for our own, where there is nobody to tell apart.
  final String? authorTint;

  /// Whether this author's bubbles sit on the right.
  final bool authorRight;

  /// Whether this is a group, which is what decides if our own face is drawn
  /// beside our own messages.
  final bool inGroup;

  /// Whether a jump has just landed here, so it can be seen to be the message
  /// that was being pointed at.
  final bool found;

  /// Go to the message this one is answering.
  final void Function(Quoted quoted)? onOpenQuoted;
  final VoidCallback? onReply;

  /// The face of whoever sent this, when they have chosen one.
  ///
  /// Null is the ordinary state: `RxAvatar` draws initials from [faceName], and
  /// both ends draw the same one from the same name with nothing travelling.
  final Uint8List? face;

  /// The name the face is drawn from when there is no picture.
  final String faceName;

  /// Whether this message is being destroyed right now.
  final bool burning;

  /// Called when the fire has finished and the message can be removed.
  final VoidCallback? onGone;

  /// Reply, copy, react, withdraw. Reactions are offered only on their
  /// messages: reacting to yourself is a thing other applications allow and
  /// nobody has ever wanted.
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

  /// The sender's face, beside the first bubble of each run.
  ///
  /// Reserved rather than omitted on the rest, so a run of messages keeps one
  /// left edge instead of stepping in and out as each bubble gains or loses a
  /// face beside it.
  ///
  /// In a group, everybody's, including ours.
  ///
  /// It used to be only on what arrived, on the reasoning that nobody needs to
  /// be shown their own face. That reads fine in a conversation of two and
  /// wrong in a group: eight people each have a face beside their bubbles and
  /// the one person whose face is missing is the person reading. He asked what
  /// had happened to his picture, which is the question a gap like that makes
  /// somebody ask.
  ///
  /// A conversation of two keeps the old behaviour: there is one other person,
  /// their face is in the header, and a column of two faces is decoration.
  /// Which side this bubble sits on: ours on the right, and in a group the
  /// side the transcript handed this author. Decided upstream, in `_Sides`,
  /// because the answer depends on the whole conversation and not on one
  /// bubble.
  bool get _onRight => authorRight;

  Widget _face({bool onRight = false}) {
    const size = 28.0;
    if (!showAuthor) return const SizedBox(width: size + 8);

    return Padding(
      padding: EdgeInsets.only(right: onRight ? 0 : 8, left: onRight ? 8 : 0),
      child: SizedBox(
        width: size,
        height: size,
        child: face == null
            ? RxAvatar(faceName, size: size)
            : ClipOval(
                child: Image.memory(face!,
                    width: size, height: size, fit: BoxFit.cover)),
      ),
    );
  }

  Widget _row(BuildContext context, RotelyxTheme t, bool mine) {
    final right = mine || _onRight;
    // Ours is drawn in a group and nowhere else. See `_face`.
    final withFace = !mine || inGroup;
    return Row(
        mainAxisAlignment:
            right ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (withFace && !right) _face(),
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
          if (withFace && right) _face(onRight: true),
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
    final right = mine || _onRight;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment:
          right ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
          Flexible(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.62),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              foregroundDecoration: found
                  // A jump landed here. Said with a wash of the accent over
                  // the bubble for a moment rather than by moving anything:
                  // the reader is already looking at where it landed, and a
                  // bubble that grows or slides is asking them to look again.
                  ? BoxDecoration(
                      color: Tone.accent.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(Metrics.bubble),
                    )
                  : null,
              decoration: BoxDecoration(
                // Theirs, in a group, carries a little of the colour their
                // name is written in, so a burst from one person reads as one
                // person without every bubble having to be labelled. A
                // conversation of two keeps the plain one: there is only one
                // other person and colouring them says nothing.
                color: mine
                    ? t.mine
                    : (authorTint == null
                        ? t.theirs
                        : Color.alphaBlend(
                            RxAvatar.colourFor(authorTint!)
                                .withValues(alpha: 0.20),
                            t.theirs)),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(Metrics.bubble),
                  topRight: const Radius.circular(Metrics.bubble),
                  bottomLeft: Radius.circular(right ? Metrics.bubble : 5),
                  bottomRight: Radius.circular(right ? 5 : Metrics.bubble),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (authorTint != null && showAuthor && !mine)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        authorTint!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.label.copyWith(
                            color: RxAvatar.colourFor(authorTint!), fontSize: 12),
                      ),
                    ),
                  _Body(
                      message: message, mine: mine, onOpenQuoted: onOpenQuoted),
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
                      if (message.edited) ...[
                        const SizedBox(width: 4),
                        Text('edited',
                            style: Type.small.copyWith(
                                fontSize: 9,
                                fontStyle: FontStyle.italic,
                                color: (mine ? t.mineText : t.faint)
                                    .withOpacity(0.6))),
                      ],
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
                        // Four states in a group, not three. A single tick
                        // that some people have read is not the same as one
                        // nobody has, and a double tick that means "somebody"
                        // is a small lie told to everybody.
                        if (message.seenBy.isNotEmpty && !message.seen)
                          Tooltip(
                            message: 'Read by ${message.seenBy.join(', ')}',
                            child: Text('${message.seenBy.length}',
                                style: Type.small.copyWith(
                                    fontSize: 9,
                                    color: t.mineText.withOpacity(0.8))),
                          ),
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

/// A call that nobody answered, as one line in the middle of the column.
///
/// Centred and muted on purpose. It is a fact about the conversation rather
/// than a turn in it, and the shape people already read that way is the one
/// every messenger uses for "this happened" as opposed to "somebody said".
/// Somebody knocking, and the two buttons that decide it.
///
/// # Why this is a decision and not a notification
///
/// Admitting a member takes two of them: one asks and a **different** one
/// commits, and every other member refuses a commit that admits somebody on
/// the authority of whoever sent it. So the person reading this is not being
/// informed of something that happened. They are one of the two hands.
///
/// The name is what the person knocking called themselves, which is worth
/// what an unverified name is worth, and the copy says so rather than
/// presenting it as established.
/// A line the conversation has to say, under the header, until it is read
/// or a few seconds pass.
class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text, required this.onDismiss});

  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(Metrics.pad, 0, Metrics.pad, Metrics.gap),
      child: Container(
        decoration: BoxDecoration(
          color: t.raised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.line),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: t.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: Type.body.copyWith(color: t.text, fontSize: 13)),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 16, color: t.muted),
              onPressed: onDismiss,
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

class _AdmissionRequest extends StatelessWidget {
  const _AdmissionRequest({
    super.key,
    required this.waiting,
    required this.onLetIn,
    required this.onNotNow,
  });

  final PendingAddition waiting;
  final VoidCallback onLetIn;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final who = waiting.name.isEmpty ? 'Somebody' : waiting.name;
    final asker = waiting.askedBy == null || waiting.askedBy!.isEmpty
        ? 'Someone here'
        : waiting.askedBy!;

    return Padding(
      padding:
          const EdgeInsets.fromLTRB(Metrics.pad, 0, Metrics.pad, Metrics.pad),
      child: Container(
        decoration: BoxDecoration(
          color: Tone.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Tone.accent.withValues(alpha: 0.3)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.door_front_door_outlined,
                    size: 16, color: Tone.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('$asker wants to let $who in',
                      style: Type.body.copyWith(color: t.text)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Nobody can be added by one person alone, so this waits for you '
              'or another member. "$who" is what they call themselves, not '
              'something anybody has checked.',
              style: Type.body.copyWith(color: t.muted, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onNotNow,
                  child: Text('Not now',
                      style: Type.label.copyWith(color: t.muted, fontSize: 13)),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: onLetIn,
                  child: Text('Let them in',
                      style:
                          Type.label.copyWith(color: Tone.accent, fontSize: 13)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CallLine extends StatelessWidget {
  const _CallLine({super.key, required this.message});

  final StoredMessage message;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final note = message.call;
    final mine = message.mine;

    // Missed incoming is the one worth an eye. The other three are things the
    // person already knows about, because they were the one who did them.
    final missed = note == CallNote.missed && !mine;

    final icon = switch (note) {
      CallNote.declined => Icons.phone_disabled_outlined,
      _ => mine ? Icons.call_made_outlined : Icons.call_missed_outlined,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Metrics.wide,
        vertical: 6,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: missed ? t.text : t.faint),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message.text,
              textAlign: TextAlign.center,
              style: Type.small.copyWith(color: missed ? t.muted : t.faint),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${message.at.hour.toString().padLeft(2, '0')}:'
            '${message.at.minute.toString().padLeft(2, '0')}',
            style: Type.small.copyWith(color: t.faint),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Center(
      child: Padding(
        // Room for the navigation bar underneath.
        //
        // A bottom sheet is drawn against the bottom of the window, and on a
        // phone that draws edge to edge the bottom of the window is behind the
        // system's own buttons. So the last control on each of these sat under
        // them: visible, and not reachable.
        padding: EdgeInsets.fromLTRB(
          Metrics.wide,
          Metrics.wide,
          Metrics.wide,
          Metrics.wide + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Conversation established',
                style: Type.label.copyWith(color: t.muted)),
            const SizedBox(height: 6),
            Text(
              'The address this conversation travels under changes every '
              'hour, so anyone who knew the phrase you started with cannot '
              'follow it any more.',
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
/// The picture chosen, sitting above the composer until it is sent.
///
/// It shows what will be sent and offers the one thing somebody wants here,
/// which is to change their mind. The line typed underneath goes with it.
class _WaitingPicture extends StatelessWidget {
  const _WaitingPicture({super.key, required this.file, required this.onCancel});

  final Attachment file;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(Metrics.pad, 0, Metrics.pad, 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(Metrics.radius),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 44,
              height: 44,
              child: file.isImage
                  ? RotelyxPhoto(
                      bytes: file.bytes,
                      onFailed: (_) =>
                          Icon(Icons.image_outlined, size: 24, color: t.muted),
                    )
                  : Icon(Icons.insert_drive_file_outlined,
                      size: 24, color: t.muted),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(file.isImage ? 'Picture' : file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.label.copyWith(color: t.text)),
                Text('Say something about it, or just send it',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.small.copyWith(color: t.faint)),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            icon: Icon(Icons.close, size: 18, color: t.muted),
            tooltip: 'Do not send it',
          ),
        ],
      ),
    );
  }
}

class _ReplyingTo extends StatelessWidget {
  const _ReplyingTo({
    super.key,
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

class _Composer extends StatefulWidget {
  const _Composer({
    super.key,
    required this.controller,
    required this.focus,
    required this.onSend,
    required this.onAttach,
    required this.burnSeconds,
    required this.onBurn,
    required this.conversationId,
    required this.onInspect,
    required this.onPicture,
  });

  /// Which conversation the line underneath is about.
  final String conversationId;

  /// A picture that arrived without going through the picker: handed over by
  /// the keyboard on Android, taken off the clipboard on iOS.
  final void Function(Uint8List bytes, String mime) onPicture;

  /// Open the members, which is also what marks the set as looked at.
  final VoidCallback onInspect;

  final FocusNode focus;

  /// How long the next message survives, or null when it stays.
  final int? burnSeconds;
  final VoidCallback onBurn;

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  /// Whether there is a picture on the clipboard worth offering.
  ///
  /// Asked when the field is focused and not before. The question is free and
  /// tells nobody; reading the clipboard is what raises the banner iOS shows,
  /// and that only happens if somebody taps the offer. See
  /// `platform/pasted.dart`.
  bool _pasteReady = false;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_lookForPaste);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_lookForPaste);
    super.dispose();
  }

  void _lookForPaste() {
    if (!widget.focus.hasFocus) {
      if (_pasteReady) setState(() => _pasteReady = false);
      return;
    }
    hasPastedImage().then((yes) {
      if (mounted && yes != _pasteReady) setState(() => _pasteReady = yes);
    });
  }

  Future<void> _sendPasted() async {
    setState(() => _pasteReady = false);
    final pasted = await pastedImage();
    if (pasted == null) return;
    widget.onPicture(pasted.bytes, pasted.mime);
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.line)),
      ),
      // The surface reaches the bottom of the screen and the controls sit
      // above the home indicator, rather than the bar stopping short and
      // leaving the backdrop showing underneath it.
      //
      // A `SafeArea` rather than `viewPadding` read by hand, because this one
      // has to disappear when the keyboard is up: the indicator is not drawn
      // then, and thirty four points of nothing between the field and the
      // keyboard is the same fault upside down. SafeArea already knows that.
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
        Padding(
        padding: const EdgeInsets.all(Metrics.gap + 2),
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            onPressed: widget.onAttach,
            tooltip: 'Attach a photo or a file',
            icon: Icon(Icons.attach_file, size: 20, color: t.muted),
          ),

          // Lit when the next message is going to burn, and carrying the
          // duration, because a mode this consequential should never be on
          // without saying so.
          IconButton(
            onPressed: widget.onBurn,
            tooltip: widget.burnSeconds == null
                ? 'Destroy after reading'
                : 'Burns ${burnLabel(widget.burnSeconds!)} after it is read',
            icon: widget.burnSeconds == null
                ? Icon(Icons.local_fire_department_outlined,
                    size: 20, color: t.muted)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.local_fire_department,
                          size: 20, color: Tone.fire),
                      const SizedBox(width: 3),
                      Text(burnLabel(widget.burnSeconds!),
                          style: Type.small.copyWith(
                              color: Tone.fire,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
          ),

          // The field itself carries the mode, not only the flame beside it.
          //
          // Arming this changes what happens to something the other person
          // receives, and it stays armed across messages. A twenty pixel icon
          // in a row of icons is not enough warning for that: somebody who
          // armed it four messages ago and forgot has no reason to look at the
          // icon again, but they cannot avoid looking at the box they are
          // typing into.
          Expanded(
            child: AnimatedContainer(
              duration: Motion.enter,
              curve: Motion.enterCurve,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Metrics.pill),
                boxShadow: widget.burnSeconds == null
                    ? null
                    : [
                        BoxShadow(
                          color: Tone.fire.withOpacity(0.22),
                          blurRadius: 14,
                        ),
                      ],
              ),
              child: TextField(
                controller: widget.controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                focusNode: widget.focus,
                onSubmitted: (_) => widget.onSend(),
                // What a keyboard hands over directly.
                //
                // Android only, and that is Flutter's limit rather than a
                // choice: a GIF keyboard there commits its content to the
                // field and this is where it arrives. An iPhone gives a text
                // field rich content that a Flutter field cannot take, so
                // there the same picture comes through the clipboard. See
                // `platform/pasted.dart`.
                contentInsertionConfiguration: ContentInsertionConfiguration(
                  allowedMimeTypes: const [
                    'image/gif',
                    'image/png',
                    'image/jpeg',
                    'image/webp',
                  ],
                  onContentInserted: (content) {
                    final data = content.data;
                    if (data == null) return;
                    widget.onPicture(Uint8List.fromList(data), content.mimeType);
                  },
                ),
                style: Type.body.copyWith(color: t.text),
                decoration: InputDecoration(
                  hintText: widget.burnSeconds == null
                      ? 'Message'
                      : 'Burns ${burnLabel(widget.burnSeconds!)} after it is read',
                  hintStyle: Type.body.copyWith(
                      color: widget.burnSeconds == null ? t.faint : Tone.fire),
                  filled: true,
                  fillColor: widget.burnSeconds == null
                      ? t.raised
                      : Color.alphaBlend(
                          Tone.fire.withOpacity(0.10), t.raised),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: Metrics.pad, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Metrics.pill),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Metrics.pill),
                    borderSide: widget.burnSeconds == null
                        ? BorderSide.none
                        : BorderSide(color: Tone.fire.withOpacity(0.55)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Metrics.pill),
                    borderSide: BorderSide(
                        color: widget.burnSeconds == null
                            ? Tone.accent.withOpacity(0.5)
                            : Tone.fire),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: Metrics.gap),
          Material(
            color: widget.burnSeconds == null ? Tone.accent : Tone.fire,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.onSend,
              child: const Padding(
                padding: EdgeInsets.all(11),
                child: Icon(Icons.arrow_upward, size: 19, color: Colors.white),
              ),
            ),
          ),
        ],
        ),
        ),
        // The picture somebody copied, offered rather than pasted.
        //
        // This is how a sticker reaches an iPhone application: Memoji, an
        // app's own pack and any GIF keyboard all hand their picture to the
        // keyboard's own field, which Flutter cannot take, and all of them
        // can be copied. So it is offered when there is one and never taken
        // without being asked for. See `platform/pasted.dart`.
        if (_pasteReady)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Metrics.gap + 4, 0, Metrics.gap + 4, Metrics.gap),
            child: Align(
              alignment: Alignment.centerLeft,
              child: RxButton('Send the picture you copied',
                  weight: Weight.secondary,
                  icon: Icons.content_paste_outlined,
                  onTap: _sendPasted),
            ),
          ),
        _WhoCanRead(
            conversationId: widget.conversationId,
            onInspect: widget.onInspect),
          ],
        ),
      ),
    );
  }
}


/// Who can read this conversation, under the place you type into it.
///
/// # Why this is here and not in a menu
///
/// Every documented attack on a group messenger has the same shape and none of
/// them break the encryption. A WhatsApp group's management messages are not
/// signed by the administrator, so a server can add somebody. A device linked
/// to an account through the official feature reads everything and is never
/// mentioned again. What they have in common is that the set of people the
/// message is for changed and nobody noticed.
///
/// Every messenger can already tell you who is in a conversation. All of them
/// put it one tap away, or in a line of the transcript that scrolls past and
/// is gone. That is the right place for a fact somebody might want and the
/// wrong place for a fact somebody needs at a particular moment, and the
/// moment is this one: about to say something.
///
/// So it sits under the field, it cannot be dismissed, and when the set
/// changes it says so and goes on saying so until somebody looks.
///
/// # What it does not claim
///
/// That the people are who they say. That is the safety number, and this says
/// whether it has been compared. This is a count and a state, and it is drawn
/// from the group itself rather than from anything a server said, which is the
/// one reason it can be trusted at all.
class _WhoCanRead extends StatefulWidget {
  const _WhoCanRead({required this.conversationId, required this.onInspect});

  final String conversationId;
  final VoidCallback onInspect;

  @override
  State<_WhoCanRead> createState() => _WhoCanReadState();
}

class _WhoCanReadState extends State<_WhoCanRead> {
  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    final keys = [for (final m in rotelyx.members) m.key];
    if (keys.length < 2) return const SizedBox.shrink();

    final changed = store.rosterChanged(widget.conversationId, keys);
    final verification =
        store.verificationOf(widget.conversationId, rotelyx.safetyNumber);

    final people = '${keys.length} devices';
    final String state;
    final Color colour;

    if (changed) {
      state = 'this is not who it was';
      colour = Tone.warn;
    } else {
      switch (verification) {
        case Verification.matches:
          state = 'compared';
          colour = Tone.good;
        case Verification.changed:
          state = 'the number changed';
          colour = Tone.bad;
        case Verification.never:
        case Verification.declined:
          state = 'not compared';
          colour = t.faint;
      }
    }

    return InkWell(
      onTap: () {
        // Looking is what settles it. The mark is taken as read here rather
        // than when the panel closes, because somebody who opened it has been
        // shown the answer whatever they do next.
        store.markRosterSeen(widget.conversationId, keys);
        widget.onInspect();
        setState(() {});
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            Metrics.gap + 4, 0, Metrics.gap + 4, Metrics.gap),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              changed ? Icons.error_outline : Icons.lock_outline,
              size: 12,
              color: colour,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                '$people, $state',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.small.copyWith(color: colour),
              ),
            ),
          ],
        ),
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
  const _Body({
    required this.message,
    required this.mine,
    this.onOpenQuoted,
  });

  final StoredMessage message;
  final bool mine;

  /// Tapping the quote goes to the message being answered.
  final void Function(Quoted quoted)? onOpenQuoted;

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
          GestureDetector(
            // The whole quote, not a corner of it: a person pointing at
            // "what is this answering" aims at the quote.
            behavior: HitTestBehavior.opaque,
            onTap: onOpenQuoted == null
                ? null
                : () => onOpenQuoted!.call(quoted),
            child: Container(
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // A picture being answered says "Picture" rather than the
                    // first hundred characters of its base64, which is what a
                    // quote carries when what it quotes is not words.
                    if (attachmentGlimpse(quoted.excerpt) != null) ...[
                      Icon(Icons.image_outlined,
                          size: 13, color: fg.withOpacity(0.62)),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                          attachmentGlimpse(quoted.excerpt) ?? quoted.excerpt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Type.small.copyWith(
                              fontSize: 12.5,
                              height: 1.3,
                              color: fg.withOpacity(0.62))),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ),
          SelectableText(quoted.reply, style: Type.body.copyWith(color: fg)),
        ],
      );
    }

    // A bot's card: a title, a line, and buttons under it.
    final card = BotCard.decode(body);
    if (card != null) return _CardBody(card: card, fg: fg);

    final file = Attachment.decode(body);

    if (file == null) {
      // A link to a picture, an animation, a track or a clip is drawn as the
      // thing it points at rather than as a line of text somebody has to
      // leave the application to follow. Nothing is fetched until it is
      // tapped: see `lib/rotelyx/media_link.dart`.
      final links = mediaLinksIn(body);
      if (links.isEmpty) {
        return SelectableText(body, style: Type.body.copyWith(color: fg));
      }

      final said = textWithout(body, links);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (said.isNotEmpty) ...[
            SelectableText(said, style: Type.body.copyWith(color: fg)),
            const SizedBox(height: 6),
          ],
          for (final link in links) ...[
            LinkCard(key: ValueKey(link.url), link: link, fg: fg),
            if (link != links.last) const SizedBox(height: 6),
          ],
        ],
      );
    }

    if (file.isImage) {
      final picture = GestureDetector(
        // Opened on a tap, because a picture inside a bubble is a thumbnail
        // whatever its resolution, and looking properly at one is the ordinary
        // thing to want. The viewer is where saving lives too.
        onTap: () => PhotoViewer.open(context, file: file),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: RotelyxPhoto(
            bytes: file.bytes,
            onFailed: (_) => _FileRow(file: file, fg: fg),
          ),
        ),
      );
      if (file.caption.isEmpty) return picture;

      // What was said with the picture, under it and inside the same bubble,
      // because it was one message and it should look like one.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          picture,
          const SizedBox(height: 6),
          SelectableText(file.caption, style: Type.body.copyWith(color: fg)),
        ],
      );
    }
    if (file.caption.isEmpty) return _FileRow(file: file, fg: fg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _FileRow(file: file, fg: fg),
        const SizedBox(height: 6),
        SelectableText(file.caption, style: Type.body.copyWith(color: fg)),
      ],
    );
  }
}

/// A card from a bot, with its buttons.
///
/// Pressing one sends the bot the button's own word for it and shows that it
/// was pressed. Nothing runs on this device: see `lib/rotelyx/card.dart`.
class _CardBody extends StatefulWidget {
  const _CardBody({required this.card, required this.fg});

  final BotCard card;
  final Color fg;

  @override
  State<_CardBody> createState() => _CardBodyState();
}

class _CardBodyState extends State<_CardBody> {
  /// The button pressed on this device, so it can be seen to have been.
  String? _pressed;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final fg = widget.fg;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (card.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(card.title,
                style: Type.label.copyWith(color: fg, fontSize: 14.5)),
          ),
        if (card.text.isNotEmpty)
          SelectableText(card.text, style: Type.body.copyWith(color: fg)),
        if (card.buttons.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final button in card.buttons)
                _CardKey(
                  label: button.label,
                  fg: fg,
                  chosen: _pressed == button.command,
                  onTap: _pressed != null
                      ? null
                      : () {
                          // Sent as a control message, so it reaches the bot
                          // and appears in nobody's conversation.
                          if (!rotelyx.signal(Signal.tap(button.command))) {
                            rotelyx.notice('That did not go through. '
                                'Not connected yet.');
                            return;
                          }
                          HapticFeedback.selectionClick();
                          setState(() => _pressed = button.command);
                        },
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _CardKey extends StatelessWidget {
  const _CardKey({
    required this.label,
    required this.fg,
    required this.chosen,
    required this.onTap,
  });

  final String label;
  final Color fg;
  final bool chosen;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: chosen
          ? Tone.accent.withValues(alpha: 0.35)
          : fg.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (chosen) ...[
                Icon(Icons.check, size: 14, color: fg),
                const SizedBox(width: 5),
              ],
              Text(label,
                  style: Type.label.copyWith(
                      color: onTap == null && !chosen
                          ? fg.withValues(alpha: 0.5)
                          : fg,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
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

/// A conversation that is locked, asking for its PIN.
///
/// Deliberately shows nothing else. Not the last message, not the count, not
/// the time: a locked conversation that previews itself while asking has
/// already given away what the lock was for.
class _Shut extends StatefulWidget {
  const _Shut({
    required this.conversationId,
    required this.onOpened,
    required this.onBack,
  });

  final String conversationId;
  final VoidCallback onOpened;
  final VoidCallback? onBack;

  @override
  State<_Shut> createState() => _ShutState();
}

class _ShutState extends State<_Shut> {
  final _pin = TextEditingController();
  bool _wrong = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _try() {
    if (store.openChat(widget.conversationId, _pin.text.trim())) {
      widget.onOpened();
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _wrong = true;
      _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return SwipeBack(
      onBack: widget.onBack,
      child: Container(
        decoration: groundOf(t.backdrop),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Padding(
                padding: const EdgeInsets.all(Metrics.gap),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 40, color: t.muted),
                    const SizedBox(height: Metrics.gap),
                    Text('This conversation is locked',
                        style: Type.title.copyWith(color: t.text)),
                    const SizedBox(height: 6),
                    Text(
                      _wrong
                          ? 'That is not the PIN'
                          : 'It is sealed under its own PIN',
                      style: Type.small.copyWith(
                          color: _wrong ? const Color(0xFFE0574A) : t.faint),
                    ),
                    const SizedBox(height: Metrics.gap),
                    TextField(
                      controller: _pin,
                      obscureText: true,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: Type.body.copyWith(color: t.text, letterSpacing: 6),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: t.raised,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Metrics.radius),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onChanged: (_) => setState(() => _wrong = false),
                      onSubmitted: (_) => _try(),
                    ),
                    const SizedBox(height: Metrics.gap),
                    RxButton('Open', onTap: _try),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
