/// The main surface: conversations on the left, the open one on the right.
///
/// Collapses to a single pane below [Metrics.compact], which is the width where
/// two columns stop being two columns and start being one squeezed one.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../rotelyx/rotelyx_config.dart';
import '../../rotelyx/rotelyx_service.dart';
import '../../rotelyx/ephemeral.dart';
import '../../rotelyx/quoted.dart';
import '../../rotelyx/rotelyx_store.dart';
import '../brand.dart';
import '../theme.dart';
import '../widgets.dart';
import '../gestures.dart';
import 'chat.dart';
import 'contact.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onPair,
    required this.onSettings,
  });

  final VoidCallback onPair;
  final VoidCallback onSettings;

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

  @override
  void initState() {
    super.initState();
    _reload();
    if (_openFirst && _conversations.isNotEmpty) {
      _openId = _conversations.first.id;
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
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _arrivals?.cancel();
    super.dispose();
  }

  void _reload() => setState(() => _conversations = store.loadAll());

  /// Pinned first, then by when something last happened.
  ///
  /// Sorted here rather than in the store, because "pinned" is a fact about
  /// this device's list and the store holds conversations rather than an
  /// arrangement of them.
  List<StoredConversation> _ordered(List<StoredConversation> all) {
    final out = List<StoredConversation>.of(all);
    out.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.lastActivity.compareTo(a.lastActivity);
    });
    return out;
  }

  List<StoredConversation> get _visible {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _ordered(_conversations);
    return _ordered(_conversations
        .where((c) =>
            // The nickname too. Searching for what you call somebody and not
            // finding them is the kind of small wrongness that makes a search
            // box feel broken.
            c.displayTitle.toLowerCase().contains(q) ||
            c.title.toLowerCase().contains(q) ||
            (c.lastMessage?.text.toLowerCase().contains(q) ?? false))
        .toList());
  }

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final wide = MediaQuery.of(context).size.width >= Metrics.compact;

    final list = _ConversationList(
      conversations: _visible,
      openId: _openId,
      search: _search,
      onSearch: () => setState(() {}),
      onOpen: (id) => setState(() => _openId = id),
      onOpenContact: (id) =>
          ContactSheet.open(context, id, onChanged: _reload),
      onPair: widget.onPair,
      onSettings: widget.onSettings,
    );

    if (!wide) {
      return _openId == null
          ? list
          : ChatScreen(
              conversationId: _openId!,
              onBack: () => setState(() => _openId = null),
              onChanged: _reload,
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
    required this.onPair,
    required this.onSettings,
  });

  final List<StoredConversation> conversations;
  final String? openId;
  final TextEditingController search;
  final VoidCallback onSearch;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onOpenContact;
  final VoidCallback onPair;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);

    return Container(
      color: t.surface,
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
                  const RxChip('post-quantum', tone: Tone.accent),
                  const Spacer(),
                  IconButton(
                    onPressed: onSettings,
                    icon: Icon(Icons.settings_outlined, size: 20, color: t.muted),
                    tooltip: 'Settings',
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
            Expanded(
              child: conversations.isEmpty
                  ? _NoConversations(onPair: onPair)
                  : PullForSettings(
                      onReach: onSettings,
                      child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: Metrics.gap),
                      itemCount: conversations.length,
                      itemBuilder: (_, i) => _ConversationTile(
                        conversation: conversations[i],
                        selected: conversations[i].id == openId,
                        onTap: () => onOpen(conversations[i].id),
                        onOpenContact: () => onOpenContact(conversations[i].id),
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
  });

  final StoredConversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpenContact;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    final last = conversation.lastMessage;
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
        onLongPress: onOpenContact,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Their picture when they have sent one, their initial when they
              // have not. Both are 42 across so the rows do not shift when one
              // arrives.
              if (conversation.picture != null)
                ClipOval(
                  child: Image.memory(conversation.picture!,
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
                          : '${last.mine ? "You: " : ""}'
                              '${Quoted.plain(Ephemeral.plain(last.text))}',
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
  const _NoConversations({required this.onPair});
  final VoidCallback onPair;

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
      color: t.backdrop,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Center(child: RxWordmark(height: 104)),
              const SizedBox(height: Metrics.gap),
              Text(
                'Messages are sealed with MLS and a hybrid post-quantum key '
                'schedule. No account, no phone number, no directory.',
                textAlign: TextAlign.center,
                style: Type.body.copyWith(color: t.muted),
              ),
              const SizedBox(height: Metrics.wide),
              Wrap(
                spacing: Metrics.gap,
                runSpacing: Metrics.gap,
                alignment: WrapAlignment.center,
                children: [
                  const RxChip('X-Wing · ML-KEM-768', icon: Icons.shield_outlined),
                  const RxChip('MLS', icon: Icons.lock_outline),
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
