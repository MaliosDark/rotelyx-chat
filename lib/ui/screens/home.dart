/// The main surface: conversations on the left, the open one on the right.
///
/// Collapses to a single pane below [Metrics.compact], which is the width where
/// two columns stop being two columns and start being one squeezed one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rotelyx/alerts.dart';
import '../../rotelyx/rotelyx_config.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../../rotelyx/signal.dart';
import '../brand.dart';
import '../theme.dart';
import '../widgets.dart';
import '../gestures.dart';
import 'chat.dart';
import 'contact.dart';

/// A conversation something outside the list asked to have opened: a tapped
/// notification. The serial makes two requests for the same conversation two
/// requests.
class OpenRequest {
  const OpenRequest(this.conversationId, this.serial);
  final String conversationId;
  final int serial;
}

/// How the shell asks the list to close whatever it has open.
///
/// The back gesture arrives at the top of the application, which does not know
/// whether a conversation is open: that is this screen's business. Rather than
/// lifting the open conversation up a level for the sake of one gesture, the
/// shell holds one of these and the list fills it in.
class HomeBack {
  VoidCallback? close;

  /// Closes what is open, and says whether there was anything to close.
  bool call() {
    final go = close;
    if (go == null) return false;
    go();
    return true;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.open,
    required this.onPair,
    required this.onSettings,
    required this.onWiped,
    required this.back,
    this.covered = false,
  });

  final OpenRequest? open;
  final VoidCallback onPair;
  final VoidCallback onSettings;

  /// Everything was deleted from the list. The same callback Settings uses:
  /// what follows is the lock screen, because there is nothing behind it.
  final VoidCallback onWiped;

  /// Filled in by this screen so the back gesture can close a conversation.
  final HomeBack back;

  /// Whether something of the shell's own is sitting over the list, in which
  /// case the back gesture is that screen's and not this one's.
  final bool covered;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<StoredConversation> _conversations = [];
  String? _openId;
  final _search = TextEditingController();

  /// Screenshot fixture: open the first conversation on load. Compiled out of
  /// any build that does not pass the define.
  static const _openFirst =
      bool.fromEnvironment('openFirst', defaultValue: false);

  /// Cancelled in [dispose], because a stream that outlives the screen calls
  /// `setState` on something that is gone.
  StreamSubscription<RotelyxMessage>? _arrivals;

  /// Messages for the conversations that are *not* open, which is every one of
  /// them while this screen is showing. Without this the list heard only about
  /// the conversation being persisted to, so a group that received ninety
  /// messages said what it said the last time it was opened.
  StreamSubscription<({String conversationId, StoredMessage message})>?
      _elsewhere;

  @override
  void initState() {
    super.initState();
    _reload();
    if (_openFirst && _conversations.isNotEmpty) {
      // A frame later, not here. Opening during the first build mounts
      // ChatScreen inside it, and what that screen does on the way up marks
      // this element dirty before it has ever been clean, which trips
      // `Element.rebuild`'s `!_dirty` assertion and paints a red error over
      // the screenshot. Tapping a conversation does the same work one frame
      // later, so this waits for the same moment the real path uses.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _show(_conversations.first.id);
      });
    }

    // A message arriving while this screen is showing has to appear on it.
    //
    // It did not. The list was read once, in this method, and refreshed only
    // when a child screen said it had changed something. So a message that
    // arrived while somebody was looking at their conversations left the row
    // reading "No messages yet" with the message already in the log, and the
    // unread badge did not appear until the list was left and reopened.
    //
    // Found by pairing a phone with a browser and watching the phone: the
    // service had written the message down correctly and the list simply never
    // asked again. The list is not the owner of that state, so it has to be
    // told, and this is what tells it.
    _arrivals = rotelyx.messages.listen((_) {
      if (mounted) _reloadSoon();
    });
    _elsewhere = rotelyx.arrivedElsewhere.listen((_) {
      if (mounted) _reloadSoon();
    });

    // And the collecting itself, which used to happen only inside a
    // conversation. See `RotelyxService.watchFromTheList`.
    _watchOrNot();
    _answer(widget.open);
  }

  /// The request that was last acted on, so a rebuild does not act on it
  /// twice and the same conversation asked for again is acted on again.
  int _answered = 0;

  @override
  void didUpdateWidget(covariant HomeScreen old) {
    super.didUpdateWidget(old);
    _answer(widget.open);
  }

  /// Open what a notification asked for, a frame later for the reason the
  /// first-open path above gives.
  void _answer(OpenRequest? request) {
    if (request == null || request.serial == _answered) return;
    _answered = request.serial;
    if (store.load(request.conversationId) == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _show(request.conversationId);
    });
  }

  /// Collect while the list is what is on screen, and stand aside when a
  /// conversation is open: that one owns the mailbox and watches the others
  /// itself.
  void _show(String? id) {
    setState(() => _openId = id);
    _watchOrNot();
  }

  void _watchOrNot() {
    if (_openId == null) {
      unawaited(rotelyx.watchFromTheList());
    } else {
      rotelyx.stopWatchingFromTheList();
    }
  }

  @override
  void dispose() {
    _arrivals?.cancel();
    _elsewhere?.cancel();
    _nextBurn?.cancel();
    super.dispose();
  }

  void _reload() {
    setState(() => _conversations = store.loadAll());
    _waitForTheNextBurn();
  }

  /// Reload at most five times a second, however many messages arrive.
  ///
  /// A phone that has been away collects its backlog in one go: hundreds of
  /// messages in a few seconds, each of which used to rebuild this whole list.
  /// What is wanted is the list after the burst, not one frame per message in
  /// it, and the difference between those two is whether the application is
  /// still responding while it catches up.
  void _reloadSoon() {
    if (_reloadPending) return;
    _reloadPending = true;
    Timer(const Duration(milliseconds: 200), () {
      _reloadPending = false;
      if (mounted) _reload();
    });
  }

  bool _reloadPending = false;

  /// Wakes the list at the moment the soonest message destroys itself.
  ///
  /// Without it the order goes stale exactly where it matters. A countdown
  /// starts when a message is read, not when it arrives, so the reload that
  /// arrival triggers happens too early to see it; and when the message finally
  /// goes, nothing tells the list to stop putting that conversation at the top.
  ///
  /// One timer, set for the next deadline, rather than a tick every second.
  /// This screen is open for as long as somebody is deciding who to talk to,
  /// and a clock running through all of that to change nothing is a clock on a
  /// battery. When nothing is counting there is no timer at all.
  Timer? _nextBurn;

  void _waitForTheNextBurn() {
    _nextBurn?.cancel();
    _nextBurn = null;

    DateTime? soonest;
    for (final c in _conversations) {
      final at = c.burnsAt;
      if (at == null) continue;
      if (soonest == null || at.isBefore(soonest)) soonest = at;
    }
    if (soonest == null) return;

    // A moment past it, so the message is already gone when the list looks
    // again rather than caught mid-burn and shown one last time.
    final wait = soonest.difference(DateTime.now()) +
        const Duration(milliseconds: 300);

    _nextBurn = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (mounted) _reload();
    });
  }

  /// Pinned first, then whatever is burning, then by when something last
  /// happened.
  ///
  /// # Why a burning conversation climbs
  ///
  /// Everything else in this list can be read later. A message counting down
  /// cannot: when it goes it is gone, and there is no version of it left
  /// anywhere to go back to. Sorting it by when it arrived puts the one thing
  /// with a deadline underneath everything without one, which is exactly
  /// backwards, and on a long list it puts it off the screen.
  ///
  /// Soonest first among them, so the order is the order they will disappear
  /// in. Pinned still wins: pinning is somebody saying where they want a
  /// conversation, and moving it because of a timer would be overruling them.
  ///
  /// Sorted here rather than in the store, because "pinned" is a fact about
  /// this device's list and the store holds conversations rather than an
  /// arrangement of them.
  List<StoredConversation> _ordered(List<StoredConversation> all) {
    final out = List<StoredConversation>.of(all);
    out.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;

      final burnA = a.burnsAt;
      final burnB = b.burnsAt;
      if ((burnA == null) != (burnB == null)) return burnA != null ? -1 : 1;
      if (burnA != null && burnB != null) return burnA.compareTo(burnB);

      return b.lastActivity.compareTo(a.lastActivity);
    });
    return out;
  }

  /// Whether the archived ones are being shown instead of the rest.
  bool _showingArchived = false;

  int get _archivedCount => _conversations.where((c) => c.archived).length;

  List<StoredConversation> get _visible {
    final q = _search.text.trim().toLowerCase();
    // Searching looks everywhere, archived included: somebody searching for a
    // name wants the conversation, not a lesson about where they put it.
    final pool = q.isEmpty
        ? _conversations.where((c) => c.archived == _showingArchived).toList()
        : _conversations;
    if (q.isEmpty) return _ordered(pool);
    return _ordered(pool
        .where((c) =>
            // The nickname too. Searching for what you call somebody and not
            // finding them is the kind of small wrongness that makes a search
            // box feel broken.
            c.displayTitle.toLowerCase().contains(q) ||
            c.title.toLowerCase().contains(q) ||
            (c.lastMessage?.text.toLowerCase().contains(q) ?? false))
        .toList());
  }

  /// What a long press on a row offers: everything that used to need opening
  /// the conversation first.
  Future<void> _rowActions(StoredConversation c) async {
    final t = RotelyxThemeScope.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: c.face == null
                        ? RxAvatar(c.displayTitle, size: 34)
                        : ClipOval(
                            child: Image.memory(c.face!,
                                width: 34, height: 34, fit: BoxFit.cover)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(c.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.title.copyWith(color: t.text)),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(c.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: t.muted),
              title: Text(c.pinned ? 'Unpin' : 'Pin to the top',
                  style: Type.body.copyWith(color: t.text)),
              onTap: () {
                c.pinned = !c.pinned;
                store.save(c);
                Navigator.of(sheet).pop();
                _reload();
              },
            ),
            ListTile(
              leading: Icon(c.muted ? Icons.notifications_off : Icons.notifications_none,
                  color: t.muted),
              title: Text(c.muted ? 'Unmute' : 'Mute',
                  style: Type.body.copyWith(color: t.text)),
              onTap: () {
                c.muted = !c.muted;
                store.save(c);
                Navigator.of(sheet).pop();
                _reload();
              },
            ),
            ListTile(
              leading: Icon(c.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
                  color: t.muted),
              title: Text(c.archived ? 'Take out of the archive' : 'Archive',
                  style: Type.body.copyWith(color: t.text)),
              subtitle: Text(
                c.archived
                    ? 'It goes back on the list.'
                    : 'Off the list, not deleted. It still receives.',
                style: Type.small.copyWith(color: t.faint),
              ),
              onTap: () {
                c.archived = !c.archived;
                store.save(c);
                Navigator.of(sheet).pop();
                _reload();
              },
            ),
            ListTile(
              leading: Icon(Icons.tune, color: t.muted),
              title: Text('Name, picture and notifications',
                  style: Type.body.copyWith(color: t.text)),
              onTap: () {
                Navigator.of(sheet).pop();
                ContactSheet.open(context, c.id, onChanged: _reload);
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Tone.bad),
              title: Text('Delete this conversation',
                  style: Type.body.copyWith(color: Tone.bad)),
              subtitle: Text(
                'Every message and the session, on this device. It cannot be '
                'undone and it does not touch their copy.',
                style: Type.small.copyWith(color: t.faint),
              ),
              onTap: () async {
                Navigator.of(sheet).pop();
                await _confirmDelete(c);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(StoredConversation c) async {
    final t = RotelyxThemeScope.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('Delete ${c.displayTitle}?',
            style: Type.title.copyWith(color: t.text)),
        content: Text(
          'Removes every message and the session. It cannot be undone and it '
          'does not touch their copy.',
          style: Type.body.copyWith(color: t.muted),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text('Keep it', style: Type.label.copyWith(color: t.muted))),
          TextButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text('Delete', style: Type.label.copyWith(color: Tone.bad))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    if (_openId == c.id) _show(null);
    store.remove(c.id);
    _reload();
  }

  /// Everything, from the list rather than from three screens in.
  ///
  /// The same act Settings offers, in the place somebody reaches for when they
  /// want it: a person who wants the phone clean wants it clean now, and
  /// "Settings, scroll, Delete everything" is not that. Both ask first, and
  /// this one says what it includes, because "all data" also means the keys
  /// and the pictures and not only the messages.
  Future<void> _confirmWipe() async {
    final t = RotelyxThemeScope.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: t.surface,
        title: Text('Delete every conversation?',
            style: Type.title.copyWith(color: t.text)),
        content: Text(
          'Every conversation, every message, every session key and every '
          'picture on this device. There is no server copy and nothing to '
          'recover it from.',
          style: Type.body.copyWith(color: t.muted),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text('Keep them', style: Type.label.copyWith(color: t.muted))),
          TextButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text('Delete everything',
                  style: Type.label.copyWith(color: Tone.bad))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    store.wipe();
    widget.onWiped();
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final wide = MediaQuery.of(context).size.width >= Metrics.compact;

    // What back means right now. On a phone it closes the conversation; on a
    // wide window the conversation sits beside the list and closing it on a
    // back gesture would be closing nothing anybody asked to open.
    widget.back.close = (widget.covered || _openId == null || wide)
        ? null
        : () => _show(null);

    final list = _ConversationList(
      conversations: _visible,
      openId: _openId,
      search: _search,
      onSearch: () => setState(() {}),
      onOpen: _show,
      onOpenContact: (id) =>
          ContactSheet.open(context, id, onChanged: _reload),
      onActions: (id) {
        final c = _conversations.firstWhere((c) => c.id == id);
        _rowActions(c);
      },
      archivedCount: _archivedCount,
      showingArchived: _showingArchived,
      onArchived: (show) => setState(() => _showingArchived = show),
      onWipeEverything: _confirmWipe,
      onPair: widget.onPair,
      // Opening it is all this does. The conversation is founded by
      // `resume`, which the chat screen already calls, so there is nothing to
      // create here and nothing to wait for.
      onNoteToSelf: () =>
          _show(RotelyxService.selfConversationId),
      onSettings: widget.onSettings,
    );

    if (!wide) {
      return SlideOver(
        under: list,
        over: _openId == null
            ? null
            : ChatScreen(
                key: ValueKey(_openId),
                conversationId: _openId!,
                onBack: () => _show(null),
                onChanged: _reload,
                // The slide below reads the drag, so the screen must not read
                // it as well.
                swipeToClose: false,
              ),
        onBack: () => _show(null),
      );
    }

    return Row(
      children: [
        SizedBox(width: 340, child: list),
        Container(width: 1, color: t.line),
        Expanded(
          child: _openId == null
              ? const _NothingOpen()
              : ChatScreen(
                  key: ValueKey(_openId),
                  conversationId: _openId!,
                  onChanged: _reload,
                ),
        ),
      ],
    );
  }
}

class _ConversationList extends StatelessWidget {
  const _ConversationList({
    required this.conversations,
    required this.openId,
    required this.search,
    required this.onSearch,
    required this.onOpen,
    required this.onOpenContact,
    required this.onActions,
    required this.onPair,
    required this.onNoteToSelf,
    required this.onSettings,
    required this.archivedCount,
    required this.showingArchived,
    required this.onArchived,
    required this.onWipeEverything,
  });

  final List<StoredConversation> conversations;
  final String? openId;
  final TextEditingController search;
  final VoidCallback onSearch;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onOpenContact;

  /// A long press: pin, mute, archive, details, delete.
  final ValueChanged<String> onActions;
  final VoidCallback onPair;
  final VoidCallback onNoteToSelf;
  final VoidCallback onSettings;

  /// How many are put away, and whether those are the ones being shown.
  final int archivedCount;
  final bool showingArchived;
  final ValueChanged<bool> onArchived;

  /// Everything on this device, asked for from the list's own menu.
  final VoidCallback onWipeEverything;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Container(
      // The ground, with a light in one corner.
      //
      // This is the surface a person actually looks at, and it was one flat
      // fill. Three attempts at giving the application some depth were made
      // against the wrong widgets: the root behind this, and a screen that is
      // only shown when nothing is open. Each measured as a change and looked
      // like nothing, because this was painted over all of them.
      decoration: groundOf(t.surface),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Metrics.pad, Metrics.pad, Metrics.gap, Metrics.gap),
              child: Row(
                children: [
                  const RxLockup(height: 21),
                  const SizedBox(width: Metrics.gap),
                  const Spacer(),
                  IconButton(
                    onPressed: onSettings,
                    icon: Icon(Icons.settings_outlined, size: 20, color: t.muted),
                    tooltip: 'Settings',
                  ),
                  // Deleting everything lives here rather than in the sheet a
                  // long press opens.
                  //
                  // It was in that sheet, one row under "Delete this
                  // conversation", because he asked for it to be reachable
                  // from the list. Two destructive actions a finger's width
                  // apart, one of which takes a single conversation and the
                  // other every conversation on the device, is a trap: it is
                  // the same shape as the one that deletes a message and the
                  // one that deletes an account. Still on the list, still two
                  // taps, and not next to anything about one row.
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, size: 20, color: t.muted),
                    tooltip: 'More',
                    color: t.surface,
                    onSelected: (chosen) {
                      if (chosen == 'wipe') onWipeEverything();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'wipe',
                        child: Row(
                          children: [
                            const Icon(Icons.delete_forever_outlined,
                                size: 18, color: Tone.bad),
                            const SizedBox(width: 10),
                            Text('Delete every conversation',
                                style: Type.body.copyWith(color: Tone.bad)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Metrics.pad),
              child: TextField(
                controller: search,
                onChanged: (_) => onSearch(),
                style: Type.body.copyWith(color: t.text),
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: Type.body.copyWith(color: t.faint),
                  prefixIcon: Icon(Icons.search, size: 18, color: t.faint),
                  filled: true,
                  fillColor: t.raised,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Metrics.radius),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Metrics.gap),

            // The way in and the way out of the archive.
            //
            // One row rather than a tab or a second screen, which is where
            // every messenger people already use puts it: it is only there
            // when something is in it, and while the archive is open it is
            // the way back.
            if (showingArchived || archivedCount > 0)
              InkWell(
                onTap: () => onArchived(!showingArchived),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Metrics.pad, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                          showingArchived
                              ? Icons.arrow_back
                              : Icons.archive_outlined,
                          size: 18,
                          color: t.muted),
                      const SizedBox(width: Metrics.gap),
                      Expanded(
                        child: Text('Archived',
                            style: Type.body.copyWith(color: t.text)),
                      ),
                      Text('$archivedCount',
                          style: Type.small.copyWith(color: t.faint)),
                    ],
                  ),
                ),
              ),

            Expanded(
              child: conversations.isEmpty
                  ? _NoConversations(onPair: onPair, onNoteToSelf: onNoteToSelf)
                  : PullForSettings(
                      onReach: onSettings,
                      child: ListView.builder(
                      // No horizontal padding here: it is on each row instead,
                      // so the rule between them runs from edge to edge rather
                      // than stopping short at both ends.
                      padding: EdgeInsets.zero,
                      itemCount: conversations.length,

                      // Which row a conversation is on now.
                      //
                      // The list is ordered by when each conversation last
                      // moved, so a message arriving anywhere reorders it.
                      // Without this the rows are matched by position, so
                      // every row becomes a different conversation, every
                      // element is rebuilt, and the entry animation below
                      // plays again for all of them: the list blinks. With it,
                      // the row that moved is the only one that moves.
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<String>) return null;
                        final at = conversations
                            .indexWhere((c) => c.id == key.value);
                        return at < 0 ? null : at;
                      },
                      itemBuilder: (_, i) => RxEnter(
                        key: ValueKey(conversations[i].id),
                        index: i,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: Metrics.gap),
                              child: _ConversationTile(
                                conversation: conversations[i],
                                selected: conversations[i].id == openId,
                                onTap: () => onOpen(conversations[i].id),
                                onOpenContact: () =>
                                    onOpenContact(conversations[i].id),
                                onActions: () => onActions(conversations[i].id),
                              ),
                            ),
                            // Between rows and not after the last one: a line
                            // under the final row is a line under nothing.
                            if (i != conversations.length - 1)
                              WavyRule(colour: t.line),
                          ],
                        ),
                      ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(Metrics.pad),
              child: RxButton('New conversation',
                  icon: Icons.add, wide: true, onTap: onPair),
            ),
          ],
        ),
      ),
    );
  }
}

/// How many of their messages have arrived since this was last opened.
///
/// A dot rather than a zero when the count is nothing: a conversation can be
/// marked unread by hand with no new message in it, and "0" in a badge is a
/// contradiction.
///
/// Muted conversations still show it, in grey. Muting silences the phone, not
/// the fact that somebody wrote.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.muted});

  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final colour = muted ? t.faint : Tone.accent;

    if (count == 0) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      );
    }

    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(Metrics.pill),
      ),
      child: Text(
        // Past ninety-nine the exact number stops being information and starts
        // being a wide badge.
        count > 99 ? '99+' : '$count',
        style: Type.small.copyWith(
            color: muted ? t.surface : Colors.white,
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onTap,
    required this.onOpenContact,
    required this.onActions,
  });

  final StoredConversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpenContact;

  /// Held down: the sheet with everything that can be done to this row.
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    // The newest thing somebody actually said. A control message written down
    // by a build that did not recognise it is skipped rather than previewed:
    // one of them showed up on his list as `rx-signal group QnVkYXBlc3Q...`.
    final last = conversation.messages.reversed
        .cast<StoredMessage?>()
        .firstWhere((m) => !Signal.isControl(m!.text), orElse: () => null);
    final unread = conversation.unreadCount;
    final waiting = conversation.hasUnread;

    return Material(
      color: selected ? Tone.accent.withOpacity(0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(Metrics.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(Metrics.radius),
        onTap: onTap,
        // Their name, their picture, pin, mute and receipts. A long press
        // rather than a swipe, because a swipe on this row already means
        // something on the platforms that have one.
        // Held down, this used to open the contact sheet, which is a screen of
        // settings and not what a held-down row means anywhere else. Now it is
        // the short list of things to do with the row itself, with the settings
        // one item inside it.
        onLongPress: () {
          HapticFeedback.selectionClick();
          onActions();
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Their picture when they have sent one, their initial when they
              // have not. Both are 42 across so the rows do not shift when one
              // arrives.
              if (conversation.face != null)
                ClipOval(
                  child: Image.memory(conversation.face!,
                      width: 42, height: 42, fit: BoxFit.cover),
                )
              else
                RxAvatar(conversation.displayTitle),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // A call happening in here, before the name.
                        //
                        // A ring used to be an event that stopped happening,
                        // so somebody who missed it had no way to learn that
                        // their friends were in a room talking. A call with
                        // more than two people is a state, and this is where a
                        // state belongs: on the row, at a glance, without
                        // opening anything.
                        if (rotelyx.callIsLiveIn(conversation.id)) ...[
                          Icon(Icons.podcasts, size: 13, color: Tone.accent),
                          const SizedBox(width: 4),
                        ],
                        if (conversation.pinned) ...[
                          Icon(Icons.push_pin, size: 12, color: t.faint),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(conversation.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Type.label.copyWith(
                                  color: t.text,
                                  fontSize: 14,
                                  // Weight carries the unread state as well as
                                  // the badge, so it reads at a glance down a
                                  // long list and for anyone who cannot pick a
                                  // small purple circle out of a dark row.
                                  fontWeight: waiting
                                      ? FontWeight.w800
                                      : FontWeight.w600)),
                        ),
                        if (conversation.muted) ...[
                          const SizedBox(width: 5),
                          Icon(Icons.notifications_off_outlined,
                              size: 12, color: t.faint),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      last == null
                          ? 'No messages yet'
                          // A reply's body is wrapped with the message it
                          // answers, and one line is no place for a quote.
                          // An attachment reads as what it is. Its body is
                          // the marker and the bytes, so shown as text it was
                          // `rx-file`, a filename, an escaped type and the
                          // start of the base64, which looked like a fault.
                          : '${last.mine ? "You: " : ""}'
                              '${Alerts.preview(last.text)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.small.copyWith(
                          color: waiting ? t.muted : t.faint),
                    ),
                  ],
                ),
              ),
              if (last != null) ...[
                const SizedBox(width: Metrics.gap),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_shortTime(last.at),
                        style: Type.small.copyWith(
                            color: waiting ? Tone.accent : t.faint,
                            fontSize: 11)),
                    if (waiting) ...[
                      const SizedBox(height: 5),
                      _UnreadBadge(count: unread, muted: conversation.muted),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NoConversations extends StatelessWidget {
  const _NoConversations({required this.onPair, required this.onNoteToSelf});
  final VoidCallback onPair;

  /// Opens the conversation with yourself.
  ///
  /// Here because this is the screen somebody with nobody to write to gets
  /// stuck on, and it is the one place in the app that can be used before a
  /// second person exists.
  final VoidCallback onNoteToSelf;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Metrics.wide),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 34, color: t.faint),
            const SizedBox(height: Metrics.pad),
            Text('No conversations',
                style: Type.label.copyWith(color: t.muted)),
            const SizedBox(height: 6),
            Text(
              'There is no directory to look anyone up in. '
              'You start a conversation by agreeing a phrase, or by sending '
              'someone an invitation.',
              textAlign: TextAlign.center,
              style: Type.small.copyWith(color: t.faint),
            ),
            const SizedBox(height: Metrics.wide),
            RxButton(
              'Write a note to myself',
              icon: Icons.edit_note,
              weight: Weight.secondary,
              onTap: onNoteToSelf,
            ),
          ],
        ),
      ),
    );
  }
}

class _NothingOpen extends StatelessWidget {
  const _NothingOpen();

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final host = Uri.parse(rotelyxConfig.mailbox).host;

    return Container(
      // The ground, which is a light falling from one corner rather than a
      // flat fill. Painted here rather than left to the root because this
      // screen used to paint its own colour over it, which is why the first
      // two attempts at this were invisible on every screen that mattered.
      decoration: groundOf(t.backdrop),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Center(child: RxWordmark(height: 104)),
              const SizedBox(height: Metrics.gap),
              Text(
                'Nothing here is tied to you. No account, no phone number, '
                'and no directory to be listed in.',
                textAlign: TextAlign.center,
                style: Type.body.copyWith(color: t.muted),
              ),
              const SizedBox(height: Metrics.wide),
              Wrap(
                spacing: Metrics.gap,
                runSpacing: Metrics.gap,
                alignment: WrapAlignment.center,
                children: [
                  // The precise names live in settings, one fold down. Here
                  // they would be the first thing an empty screen says to
                  // somebody who has not sent a message yet.
                  const RxChip('Post-quantum', icon: Icons.shield_outlined),
                  const RxChip('End to end encrypted', icon: Icons.lock_outline),
                  RxChip(host, icon: Icons.inbox_outlined),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _shortTime(DateTime t) {
  final now = DateTime.now();
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  if (sameDay) {
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }
  final days = now.difference(t).inDays;
  if (days < 7) return '${days}d';
  return '${t.day}/${t.month}';
}
