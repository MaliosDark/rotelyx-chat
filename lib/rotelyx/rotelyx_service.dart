/// The Rotelyx conversation: identity, pairing, and message flow.
///
/// This is the only implementation of the handshake. The JS bridge holds no
/// protocol logic precisely so the two cannot drift.
///
/// ## What the handshake carries, and why none of it needs to be private
///
/// A key package is public and signed. A welcome is encrypted to the joiner's
/// own key. A hybrid ciphertext is encapsulated to their public key. The mailbox
/// operator sees that two parties paired and cannot derive the group secret
/// from any of it.
///
/// What the pairing does **not** provide is authentication. Whoever answers
/// first at a meeting place completes the handshake, intended party or not.
/// Only comparing the safety number out of band detects that, which is why
/// [safetyNumber] is surfaced rather than hidden behind a details panel.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import '../platform/widgets.dart';
import 'burn_clock.dart';
import 'mailbox_client.dart';
import 'meeting_code.dart';
import '../platform/apple_push.dart';
import 'push.dart';
import 'rotelyx_config.dart';
import 'rotelyx_store.dart';
import 'rotelyx_wasm.dart';
import 'signal.dart';

/// Which side of the pairing this device is.
///
/// The asymmetry is real, not cosmetic: the host founds the group and issues
/// the invitation, the guest joins one that already exists.
enum PairingRole { host, guest }

enum RotelyxState {
  /// No session yet.
  idle,

  /// Waiting at a meeting place for the other side to arrive.
  pairing,

  /// MLS established, messages flowing.
  joined,

  /// Unrecoverable; see [RotelyxService.lastError].
  failed,
}

/// How far a message got.
///
/// Deliberately stops at "in their mailbox". Read receipts would need the
/// recipient to send something back on every message, which costs a full
/// fan-out each and tells the operator when someone is reading, buying a tick
/// with the metadata the design exists to withhold.
enum Delivery { sending, inMailbox, refused }

class RotelyxMessage {
  RotelyxMessage({
    required this.text,
    required this.mine,
    required this.at,
    this.delivery = Delivery.inMailbox,
  });

  final String text;
  final bool mine;
  final DateTime at;

  /// Only meaningful for our own messages.
  Delivery delivery;
}

/// Somebody waiting to be let into a conversation, and nobody has said yes yet.
///
/// Admitting a member takes two of them: one asks and a **different** one
/// turns it into a commit. Every other member refuses a commit that admits
/// somebody on the authority of whoever sent it, so this is not a courtesy
/// the asking device could skip.
class PendingAddition {
  PendingAddition({
    required this.name,
    required this.askedBy,
    required this.meetingTag,
    required this.at,
  });

  /// What the person asking to come in calls themselves.
  ///
  /// Unverified, and an interface showing it has to say so: it is a label
  /// chosen by whoever is knocking, not a fact the group established.
  final String name;

  /// The member who asked, as the label they joined under, or null when the
  /// request could not be attributed to one.
  final String? askedBy;

  /// Where to leave the welcome once somebody agrees. The asking member's
  /// meeting place, which is theirs and not derivable here.
  final String meetingTag;

  final DateTime at;
}

class RotelyxService {
  RotelyxService({RotelyxConfig config = rotelyxConfig}) : _config = config;

  final RotelyxConfig _config;

  /// The mailbox for the conversation being opened, when an invitation named
  /// one other than this build's own.
  ///
  /// Set from the code rather than from settings, because the person who made
  /// the invitation is already waiting somewhere and the one accepting has to
  /// go there. Cleared when a conversation ends so the next one starts from the
  /// configured host again.
  String? _mailboxOverride;

  /// Where this service will connect.
  ///
  /// Three answers, in order. An invitation names one and that wins, because
  /// the person who sent it is already waiting there. Otherwise whatever this
  /// device was set to. Otherwise the one this build ships with.
  String get mailboxUrl =>
      _mailboxOverride ?? store.mailboxChoice ?? _config.mailbox;

  WasmSession? _session;
  MailboxClient? _mailbox;
  String? _meetingTag;

  /// An addition somebody asked for and nobody has confirmed yet.
  ///
  /// Held in memory rather than written down. A request is answered in the
  /// minutes after it is made, by whoever is looking at their phone, and a
  /// proposal that outlives the session it arrived in refers to a key package
  /// and an epoch that have moved on. Losing it costs the person asking one
  /// retry; keeping it would cost somebody confirming an addition they can no
  /// longer read the details of.
  PendingAddition? pendingAddition;
  PairingRole? _role;
  String _displayName = 'anon';

  /// Messages sent and not yet acknowledged, oldest first.
  ///
  /// The mailbox acks in the order it accepts, and a fan-out is deposited as a
  /// run of envelopes, so the count of outstanding envelopes is what closes a
  /// message out rather than any id, there is no message id on the wire, by
  /// design.
  final _pending = <RotelyxMessage, int>{};

  Timer? _rotation;

  /// Listeners on the current mailbox, so replacing it detaches them.
  ///
  /// Without this a retry leaves the previous client's listeners attached, and
  /// anything that client says afterwards is applied to the attempt that
  /// replaced it. Closing the old socket then failed the new one.
  final _mailboxListeners = <StreamSubscription<Object?>>[];

  int _subscribedBucket = -1;
  final Set<String> _listening = {};

  RotelyxState state = RotelyxState.idle;
  String? lastError;

  final _messages = StreamController<RotelyxMessage>.broadcast();
  final _stateChanges = StreamController<RotelyxState>.broadcast();

  Stream<RotelyxMessage> get messages => _messages.stream;
  Stream<RotelyxState> get stateChanges => _stateChanges.stream;

  /// Something the person needs told while the conversation is still working.
  ///
  /// Separate from [stateChanges] because these are not state: the connection
  /// is fine and something specific was refused. Separate from failing the
  /// conversation because a spent allowance is not a broken conversation, and
  /// dropping into `failed` for it would throw somebody out of a chat that
  /// still works.
  ///
  /// This exists because the mailbox's own error channel was only acted on
  /// while **not** joined, so a refusal that arrived mid-conversation, which is
  /// when deposits actually happen, was dropped without a word.
  Stream<String> get notices => _notices.stream;
  final _notices = StreamController<String>.broadcast();

  /// A fingerprint of the conversation, for confirming out of band that two
  /// devices are in the same group and not in two groups an attacker sat
  /// between. Null before the group exists.
  String? get safetyNumber {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return null;
    try {
      return session.safetyNumber();
    } on Object {
      return null;
    }
  }

  int get epoch => _session?.epoch ?? 0;
  int get memberCount => _session?.memberCount ?? 0;

  /// The other half of a conversation with yourself.
  ///
  /// # Why a note to self needs two of anything
  ///
  /// It reads like it should be a group of one, and it cannot be. The blind
  /// mailbox derives its tag key from the group, and the engine has no tag key
  /// until a second member exists: `session.sealForGroup` on a solo group fails
  /// with "the conversation has no second member yet". A group of one has no
  /// address, so nothing can be deposited and nothing can be polled.
  ///
  /// So both members are this device. It founds a group, invites itself, and
  /// joins. To the mailbox that is two people and nothing about it is special
  /// cased, which is the property worth having: a note written here exercises
  /// the same MLS group, the same rotating tags and the same delivery as a
  /// message to somebody else. `test/note_to_self_test.dart` holds the proof.
  ///
  /// This half only ever listens. Sending stays exactly as it was, from
  /// [_session], so no existing path changes shape.
  WasmSession? _selfPeer;

  /// Whether the open conversation is the one with yourself.
  bool get isNoteToSelf => _selfPeer != null;

  /// Replace the live session, releasing whatever it replaces.
  ///
  /// A browser collects a discarded session; the native engine keeps it in a
  /// registry until told otherwise. Every path that abandons one comes through
  /// here so that neither platform needs the caller to remember which it is on.
  void _useSession(WasmSession? next) {
    final previous = _session;
    if (identical(previous, next)) return;

    // Sealed on the way out, and this is the whole reason a restored session
    // used to need a fresh key.
    //
    // A session was thrown away here without being written down, so everything
    // that had moved the ratchet since the last *message* was lost: read
    // receipts, reactions, profile pictures, and every commit received. The
    // blob on disk was therefore genuinely behind, the copy read back from it
    // genuinely could not send, and `rekeyAfterRestore` existed to paper over
    // that by moving the epoch.
    //
    // Which was the thing that split the two ends apart, because both did it.
    // Sealing here is what makes the blob current, so a reopened conversation
    // is where it left off rather than behind.
    //
    // `_persistId` still names the conversation being left: every caller sets
    // it after this, which is what makes sealing the outgoing one correct here.
    if (previous != null) {
      final id = _persistId;
      if (id != null) {
        try {
          store.saveSession(id, previous);
          store.setSessionSealedClean(id, true);
        } on Object {
          // A session that will not seal is one this device cannot reopen, and
          // the next `resume` finds an older blob and rekeys, which is the old
          // behaviour rather than a new failure. Not worth losing the
          // conversation that is being opened over it.
        }
      }
    }

    _session = next;
    previous?.dispose();
  }

  /// Release the second half. Same contract as [_useSession].
  void _usePeer(WasmSession? next) {
    final previous = _selfPeer;
    if (identical(previous, next)) return;
    _selfPeer = next;
    previous?.dispose();
  }

  /// Emit a message and write it down.
  ///
  /// # Why the service records rather than the screen
  ///
  /// The conversation screen used to do this, appending to the stored
  /// conversation in its stream listener. That works exactly while it is on
  /// screen. A message arriving while the user is on the list, in settings, or
  /// with the application in the background was emitted to a broadcast stream
  /// with no listener and never written anywhere.
  ///
  /// It was found by pairing a phone with a browser: the browser sent a
  /// message, the phone was still on the pairing screen, and opening the
  /// conversation afterwards showed nothing. A widget is the wrong place to own
  /// durability, because a widget is allowed not to exist.
  void _emit(RotelyxMessage message) {
    _messages.add(message);
    _record(message);
    _persist();
  }

  /// Append to the conversation this service is persisting to, if any.
  void _record(RotelyxMessage m) {
    final id = _persistId;
    if (id == null) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    conversation.messages.add(StoredMessage(
      text: m.text,
      mine: m.mine,
      at: m.at,
      author: m.mine ? '' : conversation.title,
      inMailbox: m.delivery == Delivery.inMailbox,
    ));
    conversation.lastActivity = m.at;
    store.save(conversation);
  }

  /// Write a call that left nothing behind into the conversation.
  ///
  /// # Why this is here and not in `Calls`
  ///
  /// For the same reason `_record` is: this service owns what is durable. The
  /// call machinery knows a call ended and knows nothing about which
  /// conversation is being persisted to, and a widget that happened to be on
  /// screen is the wrong place to own history, which is written down at
  /// [_emit].
  ///
  /// The state is re-announced rather than a message being pushed onto
  /// [messages]. Screens reload the conversation from the store when the state
  /// changes, which they already do, and the live stream carries messages that
  /// travelled: this one did not travel, it happened here. Both sides write
  /// their own line about the same call, because both sides know their own half
  /// of it and neither has to be told.
  void recordCall(CallNote note, {required bool mine, required String text}) {
    final id = _persistId;
    if (id == null) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    final at = DateTime.now();
    conversation.messages.add(StoredMessage(
      text: text,
      mine: mine,
      at: at,
      author: mine ? '' : conversation.title,
      call: note,
    ));
    conversation.lastActivity = at;
    store.save(conversation);

    _stateChanges.add(state);
  }

  /// Rewrite a message's delivery state once the mailbox has answered.
  ///
  /// [StoredMessage] is immutable, so the entry is replaced rather than
  /// mutated. Matched on text and timestamp, which is enough: the alternative
  /// is a message id, and there is no message id on the wire by design.
  void _recordDelivered(RotelyxMessage m) {
    final id = _persistId;
    if (id == null) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    for (var i = conversation.messages.length - 1; i >= 0; i--) {
      final stored = conversation.messages[i];
      if (stored.mine && stored.text == m.text && stored.at == m.at) {
        conversation.messages[i] = StoredMessage(
          text: stored.text,
          mine: true,
          at: stored.at,
          inMailbox: true,
        );
        store.save(conversation);
        return;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Control messages
  // -------------------------------------------------------------------------

  /// Apply something that was not written by a person.
  ///
  /// Anything this build does not handle is dropped rather than shown. A
  /// control message from a newer version is not a sentence, and putting it in
  /// the conversation as one is how a future feature turns into a line of
  /// gibberish in somebody's history.
  /// Open an envelope with the second half, purely to know it arrived.
  ///
  /// Nothing is emitted. The note is already on screen, written locally the
  /// moment it was sent, which is also why this keeps working with the mailbox
  /// unreachable. What this adds is the knowledge that the round trip really
  /// happened, rather than a message that only ever existed on this disk.
  void _peerConfirm(String envelopeB64) {
    final peer = _selfPeer;
    if (peer == null) return;

    try {
      final payload = peer.openMine(envelopeB64, _config.lookback);
      // Decrypting advances the peer's ratchet, which has to happen in order or
      // the next one will not open. The plaintext itself is discarded.
      peer.receive(payload);
      // Consumed: the ratchet moved, so a re-delivery of this one would not
      // open anyway. Releasing it is the only thing that keeps a note to self
      // from leaving seven days of envelopes behind it.
      _acknowledge(envelopeB64);
    } on Object {
      // Not for this half either, or out of window. Nothing to do and nothing
      // worth telling anybody.
    }
  }

  /// [from] is the label MLS authenticated as the author, or null when the
  /// bridge could not say.
  void _onSignal(Signal signal, {String? from}) {
    switch (signal.kind) {
      case SignalKind.burnRead:
        _theyRead(signal.burnIds);
      case SignalKind.read:
        _theySawUpTo(signal.readThrough, from: from);
      case SignalKind.reaction:
        _theyReacted(signal, from: from);
      case SignalKind.profile:
        _theyChangedPicture(signal.picture);
      case SignalKind.retract:
        _theyWithdrew(signal.retractedAt);
      case SignalKind.edited:
        _theyEdited(signal.editedAt, signal.editedText);
      case SignalKind.history:
        _theyHandedHistory(signal, from: from);
      case SignalKind.pendingAddition:
        _theyWantToAdmitSomebody(signal, from: from);

      case SignalKind.report:
        _theyReported(signal, from: from);

      case SignalKind.call:
        // Which conversation has a call happening in it, before passing it on.
        //
        // A ring used to be a thing that happened and then stopped happening,
        // with nothing left behind: a person who missed it, or who was in
        // another conversation, had no way to learn that four of their friends
        // were in a room talking. A call with more than two people is a room,
        // and a room is a state rather than an event.
        _noteCallState(signal);

        // Ringing, answering, hanging up. Passed straight out rather than
        // acted on here: whether a call may start is a question about what is
        // on screen, and this object has no idea what is on screen.
        _calls.add(signal);
    }
  }

  /// Somebody handed over their copy of what was said before we arrived.
  ///
  /// # What is kept and what is refused
  ///
  /// Only messages older than the oldest this device already has. A handover is
  /// for the part that could not be read, and taking anything newer would let
  /// one member rewrite a conversation everybody else can see for themselves.
  ///
  /// Every line keeps the name of whoever handed it over, because that is what
  /// it is: one person's copy, not something the group asserts. An interface
  /// that showed it as ordinary history would be claiming a fact nobody can
  /// check.
  /// Somebody in the group wants to let a person in.
  ///
  /// Nothing has happened. The MLS proposal that arrived alongside this is in
  /// the session's queue, and it stays there, changing nothing, until a member
  /// who is not the one that asked turns it into a commit. This is the moment
  /// worth interrupting somebody for: afterwards it is already done.
  /// Somebody reported a message in this conversation.
  ///
  /// # Why this is written down rather than shown at once
  ///
  /// The people who can act on it are the conversation's admins, and they may
  /// not be looking. A report that arrives as a banner and is gone is a report
  /// nobody acted on, and the requirement it answers is about acting.
  ///
  /// Kept on the conversation, so it survives being closed, and shown to
  /// anybody who can remove a member.
  void _theyReported(Signal signal, {String? from}) {
    final id = _persistId;
    final at = signal.reportedAt;
    if (id == null || at == null) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    store.recordReport(
      id,
      reportedAt: at,
      reason: signal.reportReason,
      by: from ?? '',
    );
    _stateChanges.add(state);
  }

  /// Report a message to whoever runs this conversation.
  ///
  /// Everybody in it sees this, because a group is the only address MLS has.
  /// The screen that offers it says so.
  bool report(DateTime at, String reason) {
    rekeyIfOwed();
    return signal(Signal.report(at, reason));
  }

  /// Stop accepting anything from a member.
  ///
  /// Local and immediate. Nothing from them is written down, counted,
  /// notified about or drawn, from the next envelope onwards. It does not
  /// remove them from the group, which is a commit and belongs to whoever
  /// administers it: this is one person deciding what reaches their own
  /// phone, which is the thing that should never need anybody's permission.
  void block(String conversationId, String memberKey) {
    final c = store.load(conversationId);
    if (c == null || memberKey.isEmpty) return;
    if (c.blocked.contains(memberKey)) return;
    c.blocked.add(memberKey);
    store.save(c);
    _stateChanges.add(state);
  }

  /// Whether the live conversation refuses this member.
  bool _isBlocked(String memberKey) {
    final id = _persistId;
    if (id == null) return false;
    return store.load(id)?.blocked.contains(memberKey) ?? false;
  }

  /// Take the block off again.
  void unblock(String conversationId, String memberKey) {
    final c = store.load(conversationId);
    if (c == null) return;
    if (!c.blocked.remove(memberKey)) return;
    store.save(c);
    _stateChanges.add(state);
  }

  void _theyWantToAdmitSomebody(Signal signal, {String? from}) {
    final tag = signal.pendingMeetingTag;
    if (tag == null || tag.isEmpty) return;

    pendingAddition = PendingAddition(
      name: signal.pendingName,
      askedBy: from,
      meetingTag: tag,
      at: DateTime.now(),
    );

    final who = signal.pendingName.isEmpty ? 'somebody' : signal.pendingName;
    final asker = from == null || from.isEmpty ? 'Someone in this conversation' : from;
    _notices.add('$asker wants to let $who in. Nobody is in until you or '
        'another member agrees.');
    _stateChanges.add(state);
  }

  /// Ask the rest of the group to let somebody in.
  ///
  /// Two things go out. The MLS proposal, addressed to every member, which is
  /// what makes the addition possible and changes nothing by itself. And a
  /// note saying who is knocking and where the welcome should be left, because
  /// neither of those is in a key package and the member who confirms is not
  /// the member who was asked.
  void _askTheGroupToAdmit(String keyPackage, String name) {
    final live = _session;
    final meeting = _meetingTag;
    if (live == null || meeting == null) return;

    final proposal = live.propose(keyPackage);
    for (final envelope in live.sealCommitForGroup(proposal)) {
      _mailbox?.deposit(envelope);
    }
    signal(Signal.pendingAddition(meetingTag: meeting, name: name));

    // And step away from the meeting place until this resolves.
    //
    // A tag hands an envelope to exactly one listener and then releases it.
    // The welcome is produced by whoever confirms, not by this device, and if
    // this device is still listening here when it lands, it collects the
    // welcome meant for the person knocking. Nothing reports that: the joiner
    // simply waits for ever. There is nothing left to hear here anyway, the
    // key package is already in hand.
    _mailbox?.unsubscribe([meeting]);

    _notices.add('Asked the others to let $name in. It happens when one of '
        'them agrees.');
    _stateChanges.add(state);
  }

  /// Agree to an addition somebody else asked for.
  ///
  /// This is the second of the two hands. It produces the commit, and the
  /// welcome that the person waiting needs, and leaves that welcome at the
  /// meeting place the asking member named.
  ///
  /// Returns whether it happened, so a button can say so.
  bool confirmPendingAddition() {
    final waiting = pendingAddition;
    final live = _session;
    if (waiting == null || live == null) return false;

    try {
      final invitation = live.confirmAdditions();

      // The welcome goes where the person knocking is listening, which is the
      // asking member's meeting place and not ours. They stepped away from it
      // when they asked, so this reaches the joiner rather than being
      // collected by the member that is already in.
      _depositAt(waiting.meetingTag, {
        't': 'welcome',
        'name': _displayName,
        'welcome': invitation.welcome,
        'ratchetTree': invitation.ratchetTree,
      });

      for (final envelope in live.sealCommitForGroup(invitation.commit)) {
        _mailbox?.deposit(envelope);
      }

      pendingAddition = null;
      _persist();
      _resubscribe();
      _notices.add('${waiting.name.isEmpty ? 'They' : waiting.name} are in.');
      _stateChanges.add(state);
      return true;
    } on Object catch (e) {
      lastError = 'could not let them in: $e';
      _notices.add(lastError!);
      _stateChanges.add(state);
      return false;
    }
  }

  /// Say no, which here means forgetting the request rather than telling
  /// anybody.
  ///
  /// There is nothing to send. An addition happens when a member commits one,
  /// so an addition nobody commits does not happen, and a refusal that
  /// announced itself would only tell the asking member which of the others
  /// declined.
  void dismissPendingAddition() {
    if (pendingAddition == null) return;
    pendingAddition = null;
    _stateChanges.add(state);
  }

  void _theyHandedHistory(Signal signal, {String? from}) {
    final id = _persistId;
    final json = signal.handedHistory;
    if (id == null || json == null) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    final List<dynamic> rows;
    try {
      rows = jsonDecode(json) as List<dynamic>;
    } on Object {
      return;
    }

    // The line before which anything is older than this device could have
    // read. Empty means everything is, which is the case this exists for.
    final earliest = conversation.messages.isEmpty
        ? DateTime.now()
        : conversation.messages
            .map((m) => m.at)
            .reduce((a, b) => a.isBefore(b) ? a : b);

    final handed = <StoredMessage>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final m = StoredMessage.fromJson(row);
      if (!m.at.isBefore(earliest)) continue;
      handed.add(StoredMessage(
        text: m.text,
        // Never ours, whatever the copy said. These are somebody else's words
        // arriving from somebody else's device, and a line that claimed this
        // device wrote them would be the one lie this feature could tell.
        mine: false,
        at: m.at,
        author: from ?? m.author,
        call: m.call,
      ));
    }
    if (handed.isEmpty) return;

    conversation.messages.insertAll(0, handed);
    store.save(conversation);

    _notices.add('${from ?? 'Somebody'} shared ${handed.length} earlier '
        'messages. They are their copy, not the conversation\'s.');
    _stateChanges.add(state);
  }

  /// Hand this device's copy of the earlier messages to whoever is here now.
  ///
  /// Returns how many were sent, or null when there is nothing to send.
  ///
  /// The whole group receives it, because that is how everything travels here
  /// and because they are entitled to know: somebody who spoke when four
  /// people were listening should be told when a fifth is given it.
  int? handOverHistory({DateTime? before, int most = 200}) {
    final id = _persistId;
    if (id == null || state != RotelyxState.joined) return null;

    final conversation = store.load(id);
    if (conversation == null) return null;

    var rows = conversation.messages.where((m) => !m.burnt).toList();
    if (before != null) {
      rows = rows.where((m) => m.at.isBefore(before)).toList();
    }
    if (rows.isEmpty) return null;

    // The newest of them, capped. A whole history would not fit in one
    // envelope on the free tier, and a feature that silently sent less than it
    // said would be worse than one with a number on it.
    if (rows.length > most) rows = rows.sublist(rows.length - most);

    final json = jsonEncode(rows.map((m) => m.toJson()).toList());
    if (!signal(Signal.history(json))) return null;
    return rows.length;
  }

  /// Conversations with a call happening in them, by id.
  ///
  /// In memory and not written down, deliberately: a call that was live when
  /// the application was killed is not live when it comes back, and a list of
  /// rooms restored from disk would show people talking who went home hours
  /// ago.
  final Set<String> _callsInProgress = {};

  /// Whether somebody is in a call in [conversationId] right now.
  bool callIsLiveIn(String conversationId) =>
      _callsInProgress.contains(conversationId);

  /// Update that from a call signal, and say so once when it starts.
  void _noteCallState(Signal signal) {
    final id = _persistId;
    if (id == null) return;

    switch (signal.callSignal) {
      case CallSignal.ringing:
      case CallSignal.joined:
        if (_callsInProgress.add(id)) {
          final name = store.load(id)?.displayTitle ?? 'a conversation';
          _notices.add('There is a call happening in $name.');
          _stateChanges.add(state);
        }
      case CallSignal.ended:
        // Only `ended` empties the room. `left` is one person going home while
        // the rest carry on, and treating the two the same would take the room
        // off the screen for everybody because somebody's battery died.
        if (_callsInProgress.remove(id)) _stateChanges.add(state);
      case CallSignal.left:
      case CallSignal.answered:
      case CallSignal.declined:
      case CallSignal.stillRinging:
      case null:
        break;
    }
  }

  /// Mark everything of ours up to [through] as seen.
  ///
  /// A high water mark, so one envelope covers however many messages were read.
  /// The alternative, a receipt per message, would let an observer time each
  /// one individually and would cost a fan-out each.
  ///
  /// Their timestamp is not ours: each device stamps a message with its own
  /// clock. So the mark is compared against **our** copy's time, which is when
  /// we sent it, and the comparison is therefore "everything sent before they
  /// say they had read up to". That is right in the only case it has to be
  /// right in: they read in order, and anything sent after they looked is not
  /// covered.
  /// Deliver a signal as if it had arrived from [from].
  ///
  /// The receipt path is where a group differs from a pair, and the difference
  /// is invisible from outside: a pair works whatever the attribution is,
  /// because there is only one other member. A test that cannot say who a
  /// receipt came from can only ever exercise the case that already worked.
  @visibleForTesting
  void deliverSignalForTest(Signal signal, {String? from}) =>
      _onSignal(signal, from: from);

  /// [from] is who MLS authenticated as the author of the receipt.
  ///
  /// # This used to be the conversation's name, and that broke every group
  ///
  /// `conversationName` describes the whole conversation: for three people it
  /// is a string like "Alice and 2 others". Every member's receipt therefore
  /// arrived under the same name, the second one matched `seenBy.contains`, and
  /// the loop skipped it. So `seenBy` never grew past one and the tick, which
  /// waits for everybody, **never appeared in a group at all**.
  ///
  /// The value was there the whole time. MLS authenticates the sending leaf,
  /// `rotelyx-crypto` has carried it since it was written, and the wasm layer
  /// dropped it on the way out.
  ///
  /// Null falls back to the old behaviour, because an older bridge cannot say
  /// who spoke and a conversation of two is right either way: there is only one
  /// other member for the receipt to be from.
  void _theySawUpTo(DateTime through, {String? from}) {
    final who = from ?? conversationName ?? 'They';
    final others = memberCount > 1 ? memberCount - 1 : 1;

    _rewrite((messages) {
      var changed = false;
      for (var i = 0; i < messages.length; i++) {
        final next = readBy(messages[i], who, through, others);
        if (next == null) continue;
        messages[i] = next;
        changed = true;
      }
      return changed;
    });
  }

  /// Fold one reader into one message, or null when nothing changes.
  ///
  /// # Why this is a function and not four lines inside the loop
  ///
  /// It was four lines inside the loop, and the group case was wrong for as
  /// long as it existed with nothing able to say so: `memberCount` comes from a
  /// live MLS session, so exercising a group of three meant founding a group of
  /// three, and no test did. A conversation of two takes the same path and is
  /// correct whatever the attribution is, because there is only one other
  /// member the receipt can be from.
  ///
  /// Pulled out, the decision takes `others` as a number and can be asked about
  /// a group of eight without one existing.
  ///
  /// `others` is how many people other than us are in the conversation, which
  /// is how many receipts a tick has to wait for.
  @visibleForTesting
  static StoredMessage? readBy(
    StoredMessage m,
    String who,
    DateTime through,
    int others,
  ) {
    // Not ours, or already ticked: nothing a receipt can add.
    if (!m.mine || m.seen) return null;

    // A high water mark below this message covers everything up to it and not
    // this one, or anything sent after somebody looked would be marked read.
    if (m.at.isAfter(through)) return null;

    // The same person twice, which a redelivered envelope produces. Counting it
    // would show a tick before everybody had read it, which is the one thing
    // the tick exists not to do.
    if (m.seenBy.contains(who)) return null;

    final readers = [...m.seenBy, who];

    // The tick only once everybody has said so. Until then the names are kept
    // and the tick is not shown, because "somebody read it" and "everybody read
    // it" are different facts.
    return m.copyWith(seenBy: readers, seen: readers.length >= others);
  }

  /// Add or remove a reaction on one of our messages.
  /// [from] is who MLS authenticated as the author, for the same reason as
  /// [_theySawUpTo]: a reaction in a group is attributed to whoever made it,
  /// and attributing all of them to the conversation's own name collapsed
  /// several people into one.
  void _theyReacted(Signal signal, {String? from}) {
    final emoji = signal.emoji;
    if (emoji.isEmpty) return;
    final at = signal.reactionAt;

    _rewrite((messages) {
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        // Ours, because a reaction names a message by the timestamp its author
        // gave it, and the author of the message they reacted to is us.
        if (!m.mine || !m.at.isAtSameMomentAs(at)) continue;

        // Emoji to the people who chose it. Their label rather than an
        // identifier, because there is no identifier: a member is a claim they
        // made when they joined, and it is what a tooltip can honestly show.
        final who = from ?? conversationName ?? 'They';
        final next = {
          for (final entry in m.reactions.entries) entry.key: List<String>.of(entry.value)
        };
        final people = next.putIfAbsent(emoji, () => <String>[]);

        if (signal.removing) {
          if (!people.remove(who)) return false;
          if (people.isEmpty) next.remove(emoji);
        } else {
          if (people.contains(who)) return false;
          people.add(who);
        }

        messages[i] = m.copyWith(reactions: next);
        return true;
      }
      return false;
    });
  }

  /// Keep the picture they sent, or drop the one they withdrew.
  ///
  /// Empty means "go back to the drawn one", which is what the button in
  /// Settings sends. It used to be discarded here along with the malformed
  /// case, so somebody who removed their picture went on wearing it on every
  /// other phone and had no way to learn that.
  void _theyChangedPicture(Uint8List? picture) {
    final id = _persistId;
    if (id == null || picture == null) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    conversation.picture = picture.isEmpty ? null : picture;
    store.save(conversation);
    _stateChanges.add(state);
  }

  /// Apply a change to the stored messages, saving only if something moved.
  ///
  /// Every control message ends up doing this, and doing it in one place is
  /// what keeps three of them from each inventing their own way to decide
  /// whether the log is worth rewriting.
  void _rewrite(bool Function(List<StoredMessage> messages) change) {
    final id = _persistId;
    if (id == null) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    if (!change(conversation.messages)) return;
    store.save(conversation);
    _stateChanges.add(state);
  }

  /// Remove a message its author has withdrawn.
  ///
  /// Theirs only. A retract naming one of ours would let anybody in a group
  /// delete anybody's history, so the author is checked rather than trusted.
  void _theyWithdrew(DateTime at) {
    _rewrite((messages) {
      final before = messages.length;
      messages.removeWhere((m) => !m.mine && m.at.isAtSameMomentAs(at));
      return messages.length != before;
    });
  }

  /// Replace what one of their messages said.
  ///
  /// Theirs only. An edit naming one of ours would let anybody in a group
  /// rewrite anybody's words, which is worse than deleting them.
  void _theyEdited(DateTime at, String text) {
    if (text.trim().isEmpty) return;

    _rewrite((messages) {
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        if (m.mine || !m.at.isAtSameMomentAs(at)) continue;
        messages[i] = m.copyWith(text: text, edited: true);
        return true;
      }
      return false;
    });
  }

  /// Change one of ours, on both sides.
  ///
  /// The old text is replaced rather than kept. See `Signal.edited`.
  bool edit(StoredMessage message, String text) {
    if (!message.mine || text.trim().isEmpty) return false;
    if (!signal(Signal.edited(message.at, text))) return false;

    _rewrite((messages) {
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        if (!m.mine || !m.at.isAtSameMomentAs(message.at)) continue;
        messages[i] = m.copyWith(text: text, edited: true);
        return true;
      }
      return false;
    });
    return true;
  }

  /// Withdraw one of ours, from both sides.
  ///
  /// Returns false when the message is not ours to withdraw. It only asks: the
  /// other copy goes because their client removes it, and a modified client
  /// keeps it. See `Signal.retract`.
  bool retract(StoredMessage message) {
    if (!message.mine) return false;
    if (!signal(Signal.retract(message.at))) return false;

    _rewrite((messages) {
      final before = messages.length;
      messages.removeWhere((m) => m.mine && m.at.isAtSameMomentAs(message.at));
      return messages.length != before;
    });
    return true;
  }

  /// Tell them we have read this conversation, if they are to be told.
  ///
  /// Off unless the conversation says otherwise, because a receipt is an extra
  /// envelope per read and therefore something an operator counts. The switch
  /// is on the contact sheet and it says what it costs.
  void sendReadReceipt(String conversationId) {
    final conversation = store.load(conversationId);
    if (conversation == null || !conversation.receipts) return;
    if (conversationId != _persistId) return;

    final theirs = conversation.messages.where((m) => !m.mine);
    if (theirs.isEmpty) return;

    signal(Signal.read(theirs.last.at));
  }

  /// React to one of their messages, or take a reaction back.
  bool react({
    required DateTime at,
    required String emoji,
    required bool remove,
  }) =>
      signal(Signal.reaction(emoji: emoji, at: at, remove: remove));

  /// They have read these expiring messages, so our copies may start expiring.
  ///
  /// This is the whole of what makes a self destructing message destroy itself
  /// on both devices from the same moment. Until this arrives our copy has no
  /// deadline at all, which is deliberate: a message whose recipient never
  /// opened it has not been read, and burning our half of it would leave the
  /// sender believing something was seen that was not.
  void _theyRead(List<String> ids) {
    final id = _persistId;
    if (id == null || ids.isEmpty) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    final started = onAcknowledged(conversation.messages, ids.toSet());
    if (!started.changed) return;

    conversation.messages
      ..clear()
      ..addAll(started.messages);
    store.save(conversation);
    // An open conversation re-reads on a state change, so this is what makes
    // the countdown appear without the screen having to poll for it.
    _stateChanges.add(state);
  }

  /// Somebody has opened [conversationId] and read what is in it.
  ///
  /// Starts a clock on every expiring message they sent, records what to tell
  /// them, and deposits it if there is a connection to deposit through.
  /// Returns whether anything changed, so a caller showing the conversation
  /// knows whether to read it back.
  ///
  /// The identifier is a parameter rather than the session's own, because
  /// reading does not require a session. A conversation can be opened, read
  /// and closed with the application offline, and the clock has to start when
  /// that happens: waiting for a connection would make a self destructing
  /// message last as long as somebody stays on aeroplane mode.
  bool markBurnRead(String conversationId) {
    final conversation = store.load(conversationId);
    if (conversation == null) return false;

    // In a conversation with yourself, opening it is the reading: both
    // members are this device, so there is nobody else whose reading could
    // start the clock.
    final started = onRead(
      conversation.messages,
      ownMessagesToo: conversationId == selfConversationId,
    );
    if (!started.changed) return false;

    conversation.messages
      ..clear()
      ..addAll(started.messages);

    // Queued before it is attempted rather than after it fails, so a deposit
    // that throws halfway leaves the identifier recorded rather than lost.
    for (final id in started.acknowledge) {
      if (!conversation.burnAcks.contains(id)) conversation.burnAcks.add(id);
    }
    store.save(conversation);

    // The countdown has started, so the surfaces that show one need telling.
    //
    // This was missing, and it is the whole reason nobody ever saw the Dynamic
    // Island count a message down. `refreshWidgets` was called when a message
    // arrived, which is the one moment a burning message has no deadline: the
    // clock starts when the recipient reads it, and reading it is this
    // function. So the refresh ran, found nothing counting, and took the
    // countdown off; then the deadline was set here and nothing asked again.
    refreshWidgets();

    _flushBurnAcks(conversationId);
    return true;
  }

  /// Deposit any acknowledgements that have been waiting for a connection.
  ///
  /// Cleared only once the deposit has been made, so the queue survives a
  /// close, a crash and a restart, and a read that happened offline still
  /// reaches the sender when the application next joins.
  void _flushBurnAcks([String? conversationId]) {
    final id = conversationId ?? _persistId;
    // Only the live conversation can be deposited into: the envelopes are
    // sealed by its session, and there is one session.
    if (id == null || id != _persistId || state != RotelyxState.joined) return;

    final conversation = store.load(id);
    if (conversation == null || conversation.burnAcks.isEmpty) return;

    if (!signal(Signal.burnRead(conversation.burnAcks))) return;

    conversation.burnAcks.clear();
    store.save(conversation);
  }

  // -------------------------------------------------------------------------
  // Being woken
  // -------------------------------------------------------------------------

  /// Whether this platform can be woken by a push at all.
  ///
  /// False on Android, and not because Android cannot: because it does not
  /// need to. Android holds its own connection through a foreground service, so
  /// there is no third party in the path. iOS forbids that connection, so it is
  /// the one platform that has to ask Apple.
  bool get canBeWoken => pushTransport is! NoPush;

  /// Whether this device asks to be woken on the mailbox's clock.
  ///
  /// Only where there is nothing better. A ticket wakes this phone the moment
  /// something arrives, tells the mailbox nothing it could use to link the
  /// phone to a conversation, and costs one call to Apple per message. The
  /// schedule costs one every five minutes forever, and the ones that find
  /// nothing are the blank notifications people were getting.
  ///
  /// So the schedule is the fallback for a build with no notifier pinned, and
  /// not the default it had become. Somebody who has moved the switch keeps
  /// what they chose either way.
  bool get wakeOnSchedule =>
      store.wakeOnScheduleChoice ?? (_config.notifierKey == null);

  /// Ask the mailbox to wake this device on its schedule.
  ///
  /// The registration carries a push token and **no tag**. Binding a wake to a
  /// tag would put a stable device identifier beside a tag that rotates hourly,
  /// and the mailbox could then follow the token across every rotation and
  /// re-link the sequence the rotation exists to separate. See `push.dart`.
  ///
  /// Returns false when the platform has no push, when the user refused
  /// notifications, or when there is no connection yet. None of those is an
  /// error: the application still receives when it is opened.
  /// Whether the mailbox this device talks to can wake it at all.
  ///
  /// False once the mailbox has said so. Asking again every time a
  /// conversation is opened produces the same refusal and nothing else.
  bool mailboxCanWake = true;

  Future<bool> askToBeWoken() async {
    if (!canBeWoken || !mailboxCanWake) return false;

    final token = await pushTransport.obtainToken();
    if (token == null) return false;

    _wakeToken = token;
    if (state == RotelyxState.joined) {
      _mailbox?.registerWake(
          PushGrant(
            token: token,
            secret: store.wakeSecret,
            onSchedule: wakeOnSchedule,
          ));

      // And a ticket under every tag already being listened on.
      //
      // The token arrives here, when somebody turns notifications on, and by
      // then the conversation has usually been subscribed for a while.
      // `_resubscribe` leaves tickets only for tags it has just added, so
      // without this the tags that existed before this moment never got one:
      // the device registered for the schedule, waited five minutes for every
      // message, and nothing anywhere said why.
      _leaveTicketsFor(_listening.toList());
    }
    return true;
  }

  /// Stop being woken.
  ///
  /// A token the mailbox still holds is a device it still wakes, spending its
  /// battery on a feature somebody switched off.
  Future<void> stopBeingWoken() async {
    _wakeToken = null;
    // The secret, not the token. A token is an address and an address is not a
    // credential: see `push.dart`.
    _mailbox?.revokeWake(store.wakeSecret);
  }

  /// The token this device registered, so it can be withdrawn and so a
  /// reconnection can register it again without asking the platform twice.
  String? _wakeToken;

  /// Call signalling as it arrives, for whatever is showing to act on.
  Stream<Signal> get calls => _calls.stream;
  final _calls = StreamController<Signal>.broadcast();

  /// Send a control message: a receipt, a reaction, a picture.
  ///
  /// It travels exactly the way a sentence does, through MLS as an application
  /// message, so the mailbox cannot tell the two apart. It is not written
  /// down, because there is nothing about it to show later.
  bool signal(Signal s) {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return false;

    try {
      final ciphertext = session.send(s.encode());
      for (final envelope in session.sealForGroup(ciphertext)) {
        _mailbox?.deposit(envelope);
      }
      // A receipt moves the ratchet exactly as a message does, and only
      // messages were being written down. That gap is what made a reopened
      // session genuinely behind. See `_useSession`.
      _persist();
    } on Object catch (e) {
      lastError = 'could not send a receipt: $e';
      return false;
    }
    return true;
  }

  void _moveTo(RotelyxState next, {String? error}) {
    state = next;
    lastError = error;
    _stateChanges.add(next);

    // A read that happened while there was no connection is delivered here.
    // This is the only funnel every join passes through, which is why it hangs
    // off the transition rather than off each of the paths that reach it.
    if (next == RotelyxState.joined) {
      _flushBurnAcks();

      // And the wake registration, which the mailbox forgets when the socket
      // closes on its side. Re-sent rather than assumed to have survived: a
      // device that believes it is registered and is not stops receiving
      // silently, which is the failure nobody reports because nobody notices.
      final token = _wakeToken;
      if (token != null) {
        _mailbox?.registerWake(
            PushGrant(
            token: token,
            secret: store.wakeSecret,
            onSchedule: wakeOnSchedule,
          ));

        // Tickets go the same way as the registration and for the same
        // reason: the mailbox forgets both when the socket closes on its side,
        // and a device that believes it left one and did not is a device that
        // waits for the schedule without knowing it.
        _leaveTicketsFor(_listening.toList());
      }
    }
  }

  // -------------------------------------------------------------------------
  // Pairing
  // -------------------------------------------------------------------------

  /// Wait at a meeting place derived from a phrase both sides already know.
  ///
  /// The phrase must be at least 8 characters, the wasm enforces this, because
  /// a short phrase is guessable and guessing it is enough to impersonate
  /// whoever it was meant for.
  ///
  /// Whichever side calls this first becomes the [PairingRole.host].
  Future<void> pairByPhrase({
    required String phrase,
    required String displayName,
    required PairingRole role,
    String asDevice = '',
  }) async {
    _displayName = displayName;
    _role = role;
    _pairingAsDevice = asDevice;
    _meetingTag = RotelyxWasm.rendezvousTag(phrase);
    await _startPairing();
  }

  /// A fresh place for somebody to join **this** conversation, as a code.
  ///
  /// # Why a new one rather than the phrase that started it
  ///
  /// The address is a hash of the phrase, and a hash only goes one way, so the
  /// phrase itself is nowhere on this device: the conversation knows where it
  /// answers and not what was said to get there. "Give them the same phrase"
  /// was the only instruction that could be offered, and it only works for
  /// whoever still remembers it.
  ///
  /// So this mints a place of its own and starts answering there as well. The
  /// conversation is untouched: same group, same keys, same people. What
  /// changes is that there is now something to send somebody.
  ///
  /// # Why it replaces rather than adds
  ///
  /// Two open doors are two things to remember to close. The old address stops
  /// being answered, which is what `replaceInvitation` records, and the count
  /// and deadline start again with the new one. Anybody who had the old phrase
  /// and has not used it is shut out, which is the same property that makes
  /// turning an invitation off worth anything.
  ///
  /// Returns the code, or null when there is no conversation to join.
  Future<String?> newInvitationHere({Duration? validFor, int? maxUses}) async {
    final id = _persistId;
    if (id == null || state != RotelyxState.joined) return null;

    final code = newMeetingCode();
    final tag = RotelyxWasm.rendezvousTag(code);

    // Stop answering at the old place before answering at the new one, so the
    // two never overlap and an invitation that was turned off stays off.
    final old = _meetingTag;
    if (old != null && old != tag) _mailbox?.unsubscribe([old]);

    _meetingTag = tag;
    _role = PairingRole.host;
    _mailbox?.subscribe([tag]);

    store.replaceInvitation(
      id,
      tag: tag,
      until: validFor == null ? null : DateTime.now().add(validFor),
      maxUses: maxUses,
    );

    _stateChanges.add(state);
    return code;
  }

  /// Meet at the place a QR code names.
  ///
  /// Mechanically this is [pairByPhrase] with a machine-chosen phrase, and that
  /// is the entire trick behind scanning. The QR does not carry keys, because
  /// an X-Wing public key is 1216 bytes and a scannable QR holds a small
  /// fraction of that. It carries 120 random bits, both sides derive the same
  /// mailbox tag from them, and the keys go over the mailbox where their size
  /// costs nothing. See `meeting_code.dart`.
  ///
  /// The separate name is not decoration. A phrase a person invented and a code
  /// a generator produced are worth very different amounts, and a reader who
  /// finds `pairByPhrase` at a QR call site would reasonably assume the QR is
  /// carrying something a person typed.
  Future<void> pairByMeetingCode({
    required String code,
    required String displayName,
    required PairingRole role,
    String asDevice = '',
  }) =>
      pairByPhrase(
          phrase: code,
          displayName: displayName,
          role: role,
          asDevice: asDevice);

  /// Hand out a meeting that survives this application being closed.
  ///
  /// The difference from [pairByMeetingCode] is one line at the end, and it is
  /// what makes an invitation an invitation rather than a moment: the meeting
  /// is written down, so a later launch listens at it again. Whoever was
  /// invited deposits whenever they get round to it and the mailbox holds it
  /// under its own expiry.
  ///
  /// Nothing of the keys goes anywhere. They stay sealed on this device, the
  /// way a conversation's do; what travels is a place.
  Future<String> inviteByMeetingCode({
    required String displayName,
    required Duration validFor,
  }) async {
    final code = newMeetingCode();
    await pairByMeetingCode(
      code: code,
      displayName: displayName,
      role: PairingRole.host,
    );

    final session = _session;
    final tag = _meetingTag;
    if (session != null && tag != null) {
      store.saveWaiting(
        tag: tag,
        code: code,
        name: displayName,
        // Zero means never, which is what the longest choice on the pairing
        // screen has always meant. A century is not never and is the same
        // thing to everybody alive.
        until: DateTime.now()
            .add(validFor == Duration.zero
                ? const Duration(days: 36500)
                : validFor),
        session: session,
      );
    }
    return code;
  }

  /// Listen again at a meeting handed out before this launch.
  ///
  /// Returns false when there is nothing waiting, which is the ordinary case
  /// and not a failure.
  ///
  /// The session comes back sealed rather than being made afresh: the person
  /// who was invited is answering the key package they were given, and a new
  /// member would be a different one.
  Future<bool> resumeWaiting() async {
    // Never over a conversation.
    //
    // This took the session and subscribed to the meeting's tag instead of the
    // conversation's, so unlocking the application with an invitation
    // outstanding left every chat disconnected: they were not broken, nothing
    // was listening for them. One session, one thing at a time, and a
    // conversation somebody is having beats an invitation nobody has answered.
    if (state != RotelyxState.idle) return false;

    final held = store.waiting;
    if (held == null) return false;

    final blob = held['session'] as String?;
    final tag = held['tag'] as String?;
    final key = store.key;
    if (blob == null || tag == null || key == null) return false;

    try {
      _useSession(RotelyxWasm.unsealSession(blob, key));
    } on Object {
      // A blob that will not open is an invitation nobody can answer. Better
      // forgotten than left listening at a place with no way to reply.
      store.forgetWaiting();
      return false;
    }

    _displayName = held['name'] as String? ?? _displayName;
    _role = PairingRole.host;
    _meetingTag = tag;
    _session!.found();

    await _openMailbox();
    _mailbox!.subscribe([tag]);
    _moveTo(RotelyxState.pairing);
    return true;
  }

  /// Generate an invitation this device is waiting on, to be delivered out of
  /// band by paste.
  ///
  /// The code carries a key package, a hybrid public key, and a random return
  /// tag. All three are public. The return tag is 32 random bytes rather than a
  /// phrase, so unlike [pairByPhrase] there is nothing to guess, but the code
  /// still authenticates nobody, and the safety number is still the only check
  /// that matters.
  /// How long a new invitation is good for, unless told otherwise.
  ///
  /// An hour. An invitation carries the keys themselves, so one that never
  /// expires is a key sitting in somebody's message history: a link sent three
  /// months ago still worked, and whoever found it in that conversation could
  /// use it and become the other side.
  ///
  /// An hour is what a person needs to send one and have it opened. Anything
  /// longer is convenience bought with a door left open.
  static const invitationLifetime = Duration(hours: 1);

  /// Clocks disagree, and rejecting an invitation because the sender's phone is
  /// two minutes fast would be a failure nobody could diagnose from either
  /// screen. Wide enough to cover ordinary drift, far short of making the
  /// expiry meaningless.
  static const invitationSkew = Duration(minutes: 5);

  Future<String> createInvitation({
    required String displayName,
    Duration validFor = invitationLifetime,
  }) async {
    _displayName = displayName;
    _role = PairingRole.guest;

    final session = RotelyxWasm.newSession(displayName);
    _useSession(session);

    _meetingTag = _randomTag();
    await _openMailbox();
    _mailbox!.subscribe([_meetingTag!]);
    _moveTo(RotelyxState.pairing);

    return base64Encode(utf8.encode(jsonEncode({
      'v': 1,
      'name': displayName,
      // Where to meet. Absent from the first version of this code, when there
      // was one mailbox and both sides were compiled against it. With more than
      // one, an invitation that does not say leaves two people waiting in places
      // the other never visits, with nothing on either screen to explain it.
      'mailbox': mailboxUrl,
      // When it stops working. Zero means never, which is what a code from
      // before this field carried and what somebody can still choose for a
      // group whose members join over days.
      'expires': validFor == Duration.zero
          ? 0
          : DateTime.now().add(validFor).millisecondsSinceEpoch,
      'tag': _meetingTag,
      'keyPackage': session.keyPackage(),
      'hybridPublicKey': session.hybridPublicKey(),
    })));
  }

  /// Accept an invitation produced by [createInvitation] on another device.
  ///
  /// This side becomes the host: it founds the group, admits the holder of the
  /// key package in the code, and deposits the welcome under the code's return
  /// tag.
  Future<void> acceptInvitation({
    required String code,
    required String displayName,
  }) async {
    _displayName = displayName;
    _role = PairingRole.host;

    final Map<String, dynamic> invite;
    try {
      invite = jsonDecode(utf8.decode(base64Decode(code.trim()))) as Map<String, dynamic>;
    } catch (_) {
      _moveTo(RotelyxState.failed, error: 'that invitation code is not readable');
      return;
    }

    final tag = invite['tag'];
    final keyPackage = invite['keyPackage'];
    final hybridPublicKey = invite['hybridPublicKey'];
    if (tag is! String || keyPackage is! String || hybridPublicKey is! String) {
      _moveTo(RotelyxState.failed, error: 'that invitation code is missing fields');
      return;
    }

    // Expired, and said so rather than left to fail as silence. Without this
    // the pairing simply waits at a place nobody is any more, and neither
    // person has anything on screen that explains it.
    final expires = invite['expires'];
    if (expires is int && expires > 0) {
      final deadline = DateTime.fromMillisecondsSinceEpoch(expires)
          .add(invitationSkew);
      if (DateTime.now().isAfter(deadline)) {
        _moveTo(RotelyxState.failed,
            error: 'that invitation has expired. Ask them for a new one.');
        return;
      }
    }

    // Go where they are waiting. A code from a build with one mailbox carries
    // no host, and for those the configured one is the right answer and the
    // only one there was.
    final host = invite['mailbox'];
    _mailboxOverride = host is String && host.isNotEmpty ? host : null;

    _meetingTag = tag;

    final session = RotelyxWasm.newSession(displayName);
    _useSession(session);
    session.found();

    await _openMailbox();
    _mailbox!.subscribe([tag]);
    _moveTo(RotelyxState.pairing);

    _admit(
      name: invite['name'] as String? ?? 'anon',
      keyPackage: keyPackage,
      hybridPublicKey: hybridPublicKey,
    );
  }

  /// This device's own key package, for display alongside an invitation.
  String? get keyPackage {
    try {
      return _session?.keyPackage();
    } on Object {
      return null;
    }
  }

  /// The name this device goes by when it is one of several belonging to one
  /// person, or empty when it is the only one.
  ///
  /// Set for the length of a pairing and cleared after, because it changes what
  /// the session being made is: a leaf of its own belonging to a person who
  /// already has one, rather than a new person. See `docs/DEVICES.md`.
  String _pairingAsDevice = '';

  Future<void> _startPairing() async {
    final session = _pairingAsDevice.isEmpty
        ? RotelyxWasm.newSession(_displayName)
        : RotelyxWasm.newDeviceSession(_displayName, _pairingAsDevice);
    _useSession(session);

    if (_role == PairingRole.host) session.found();

    await _openMailbox();
    _mailbox!.subscribe([_meetingTag!]);
    _moveTo(RotelyxState.pairing);

    // The guest speaks first: the host has nothing to say until it knows who
    // is asking.
    if (_role == PairingRole.guest) {
      _depositRendezvous({
        't': 'hello',
        'name': _displayName,
        'keyPackage': session.keyPackage(),
        'hybridPublicKey': session.hybridPublicKey(),
      });
    }
  }

  /// Whether a reconnection is already under way.
  bool _reopening = false;

  /// Conversations already told what this person looks like, this run.
  ///
  /// A picture is up to 96 KiB and does not change between two openings of the
  /// same conversation, so sending it on every one would be paying for a fact
  /// the other side already has. Once per conversation per run is enough to
  /// cover a contact paired before a picture was chosen, and a change tells
  /// everybody as it happens.
  final Set<String> _toldMyPicture = {};

  /// Whether this device still owes the group a fresh key after unsealing.
  ///
  /// Set when a session comes off the disk, spent by the first thing this
  /// device actually sends. See [_rekeyIfOwed].
  bool _rekeyOwed = false;

  /// The socket went away. Open another one and listen where we were listening.
  ///
  /// A socket closes whenever the screen is left, the network moves, or the
  /// mailbox restarts. None of those is an error, and none of them used to be
  /// noticed either: the state stayed `joined`, `_live` in `chat.dart` stayed
  /// true, and `_resumeIfNeeded` therefore returned without reopening
  /// anything. Leaving a conversation and coming back was enough to stop
  /// receiving, with nothing on screen saying why.
  ///
  /// When the reopen fails the state drops to `idle` rather than `failed`.
  /// Nothing is unrecoverable here: the session is still sealed on the device
  /// and the next `resume` rebuilds it. What matters is that `joined` stops
  /// being claimed while nothing is delivered, because that claim is what made
  /// the screen skip the reopen.
  Future<void> _mailboxClosed() async {
    if (_reopening || state != RotelyxState.joined) return;
    _reopening = true;

    // Backing off rather than retrying on a fixed beat, because the mailbox
    // limits by address: `PER_ADDRESS_PER_MINUTE` is sixty with a burst of
    // twenty, and every attempt is a fresh socket. A reconnection that fires
    // every two seconds through an outage spends that allowance and then the
    // mailbox refuses the connection that would have worked, which looks from
    // the phone like the application breaking permanently.
    for (final wait in const [2, 6, 20]) {
      await Future<void>.delayed(Duration(seconds: wait));
      if (state != RotelyxState.joined) break;

      try {
        await _openMailbox();
        _resubscribe();

        // The meeting place too, for a host. `_resubscribe` covers the
        // conversation's own tags and knows nothing about this one, so without
        // it a newcomer knocks at nobody after a reconnection.
        final meeting = _meetingTag;
        if (meeting != null && _role == PairingRole.host) {
          _mailbox?.subscribe([meeting]);
        }
        _reopening = false;
        return;
      } on Object {
        // Keep trying, then stop. Falling out of this loop is not a failure of
        // the conversation: the session is sealed on the device and the next
        // time the screen is opened `resume` rebuilds it.
      }
    }

    _moveTo(RotelyxState.idle);
    _reopening = false;
  }

  Future<void> _openMailbox() async {
    // Close any previous attempt first.
    //
    // Pairing is retried after a wrong phrase or an unreachable mailbox, and
    // without this each retry leaves a live socket behind still subscribed to
    // the old tag. Collection removes, so those orphans compete with the
    // current attempt for the very envelopes it is waiting on.
    for (final listener in _mailboxListeners) {
      await listener.cancel();
    }
    _mailboxListeners.clear();

    await _mailbox?.close();
    _mailbox = null;
    _listening.clear();

    // A fresh connection is a fresh question. Whether a mailbox can wake a
    // device is a property of how the operator started it, and one that is
    // fixed by adding a key and restarting: without this the answer would be
    // remembered as "no" for the life of the application, and the setting
    // would stay hidden on a mailbox that had since gained the key.
    mailboxCanWake = true;

    final mailbox = MailboxClient(mailboxUrl);
    _mailbox = mailbox;

    // Held, not presented. It goes to the mailbox only if the free tier refuses
    // something: see `MailboxClient.holdToken` for why waiting is the safe
    // default rather than a saving.
    final token = RotelyxStore.instance.capabilityToken;
    if (token != null) mailbox.holdToken(token);

    _mailboxListeners.add(mailbox.envelopes.listen(_onEnvelope));
    _mailboxListeners.add(mailbox.closes.listen((_) => _mailboxClosed()));
    _mailboxListeners.add(mailbox.accepted.listen((count) {
      var left = count;
      while (left > 0 && _pending.isNotEmpty) {
        final entry = _pending.entries.first;
        final remaining = entry.value - 1;
        left--;
        if (remaining <= 0) {
          entry.key.delivery = Delivery.inMailbox;
          _pending.remove(entry.key);
          _recordDelivered(entry.key);
          _stateChanges.add(state);
        } else {
          _pending[entry.key] = remaining;
        }
      }
    }));

    _mailboxListeners.add(mailbox.errors.listen((message) {
      // A mailbox that cannot wake anybody is a mailbox missing a push key,
      // which is a thing the operator has not set up rather than a broken
      // conversation. It used to arrive here like any other refusal and fail
      // the session outright, so switching on "receive while the app is
      // closed" against a server with no key stopped messages, notes to self
      // and calls, all at once and permanently. The server's own tests key on
      // this wording.
      if (message.contains('cannot wake anyone')) {
        // Recorded and not shown. Moving it off the error stream stopped it
        // failing the session; putting it on `notices` still put it over the
        // message box, where it reads as this conversation being broken. It is
        // neither: it is a mailbox the operator started without a push key,
        // which nobody holding the phone can act on. The one place it belongs
        // is the setting that offers the feature, and Settings says it there.
        mailboxCanWake = false;
        _wakeToken = null;
        return;
      }

      if (state != RotelyxState.joined) {
        _moveTo(RotelyxState.failed, error: message);
        return;
      }
      // Joined, so the conversation is not broken and must not be failed for
      // this. It still has to be said: the refusals that arrive here are
      // things that did not happen, like a deposit the allowance would not
      // cover, and a message that did not go is exactly what a person cannot
      // find out any other way.
      lastError = message;
      _notices.add(message);
    }));

    try {
      await mailbox.connect();
    } on MailboxUnreachable catch (e) {
      _moveTo(RotelyxState.failed, error: e.message);
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Incoming
  // -------------------------------------------------------------------------

  /// Route by tag, not by phase.
  ///
  /// The post-quantum commit is deposited under the meeting tag but lands after
  /// the conversation already exists. Deciding on state would silently drop it
  /// and leave the guest an epoch behind with no error anywhere.
  void _onEnvelope(MailboxEnvelope incoming) {
    final meeting = _meetingTag;

    if (meeting != null) {
      String? payload;
      try {
        payload = RotelyxWasm.openUnder(incoming.envelope, meeting);
      } on Object {
        payload = null; // Not meeting traffic.
      }
      if (payload != null) {
        _onRendezvous(payload);
        // The meeting tag needs releasing as much as a conversation tag does,
        // and more: a knock nobody acknowledges is re-delivered on every
        // reconnect, and the meeting tag is the one a stranger can derive from
        // a code that was read aloud. Acknowledged after `_onRendezvous`, which
        // is where the handshake is applied.
        _acknowledge(incoming.envelope);
        return;
      }
    }

    _onConversation(incoming.envelope);
  }

  void _onRendezvous(String payloadB64) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(utf8.decode(base64Decode(payloadB64))) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final session = _session;
    if (session == null) return;

    switch (msg['t']) {
      // ---- host answers a knock ----
      //
      // Not gated on `state`: the host keeps answering for the life of the
      // conversation so people can arrive after it is established.
      case 'hello' when _role == PairingRole.host:
        _admit(
          name: msg['name'] as String? ?? 'anon',
          keyPackage: msg['keyPackage'] as String,
          hybridPublicKey: msg['hybridPublicKey'] as String,
        );

      // ---- guest receives the welcome ----
      case 'welcome' when _role == PairingRole.guest && state != RotelyxState.joined:
        try {
          session.join(msg['welcome'] as String, msg['ratchetTree'] as String);

          // Present for the founding pair only. Staging must precede the
          // commit: MLS looks the pre-shared key up by id and refuses the
          // commit outright if it is missing, rather than quietly continuing
          // without the post-quantum layer.
          final pq = msg['pqCiphertext'];
          if (pq is String) session.openPq(pq);
        } on Object catch (e) {
          _moveTo(RotelyxState.failed, error: 'could not join the conversation: $e');
          return;
        }
        _enterConversation();

      // ---- guest applies the post-quantum commit ----
      case 'commit' when _role == PairingRole.guest:
        try {
          session.receive(msg['commit'] as String);

          // The epoch moved, so our tags moved with it.
          //
          // Found by running it: without this the guest stays subscribed to the
          // tag set it computed at join, one epoch behind, and every message the
          // host sends is addressed to a tag nobody is listening on. Pairing
          // still completes, the safety numbers still match, and the
          // conversation is simply silent in both directions, which looks like
          // a mailbox problem and is not one.
          _resubscribe();
          _stateChanges.add(state);
        } on Object {
          // A commit we cannot process leaves the epoch behind; the safety
          // number will not match, which is the signal that matters.
        }
    }
  }

  /// Admit a member and hand them everything they need, in the order they need it.
  ///
  /// The founding pair and a later arrival are genuinely different cases, not
  /// the same case with a flag:
  ///
  ///   **Founding pair**: one encapsulation establishes the post-quantum
  ///   secret, and the welcome carries it so the joiner can stage it before the
  ///   commit lands.
  ///
  ///   **Later arrival**: the members already present have not applied this
  ///   commit, so they are still an epoch behind and must be addressed *there*.
  ///   Addressing them at the new epoch would deposit under a tag nobody
  ///   listens on, and the group would split with the host one epoch ahead and
  ///   nothing saying so.
  void _admit({
    required String name,
    required String keyPackage,
    required String hybridPublicKey,
  }) {
    final session = _session;
    if (session == null) return;

    final founding = state != RotelyxState.joined;

    if (!founding && session.memberCount >= RotelyxWasm.maxMembers) {
      lastError =
          'could not add $name: this conversation is full at ${RotelyxWasm.maxMembers} members';
      _stateChanges.add(state);
      return;
    }

    // Whether the invitation they used still opens the door.
    //
    // A meeting phrase used to be infinite and irrevocable: the tag is a hash
    // of it, so it never expired, nobody counted who had walked through, and
    // the only way to close it was to agree a different phrase with everybody
    // already inside. Somebody removed from a group could knock again with the
    // same words. An invitation is an object with limits and an owner now, and
    // this is where the limits are worth anything.
    //
    // Only for a later arrival. The founding pair is the invitation.
    final admittingTo = founding ? null : store.load(_persistId ?? '');
    if (admittingTo != null && !admittingTo.meetingIsOpen) {
      lastError = 'could not let $name in: '
          '${admittingTo.meetingClosedBecause ?? 'that invitation is closed'}';
      _notices.add(lastError!);
      _stateChanges.add(state);
      return;
    }

    try {
      // Founding is first contact: one member, and the second pair of eyes
      // would have to belong to somebody who has not arrived. Every other
      // admission takes two members, and every other member refuses a commit
      // that admits somebody on the authority of whoever sent it, so this is
      // not a choice this device gets to make.
      if (!founding) {
        _askTheGroupToAdmit(keyPackage, name);
        return;
      }

      final invitation = session.invite(keyPackage);

      if (founding) {
        _depositRendezvous({
          't': 'welcome',
          'name': _displayName,
          'welcome': invitation.welcome,
          'ratchetTree': invitation.ratchetTree,
          'pqCiphertext': session.encapsulateTo(hybridPublicKey),
        });
        _depositRendezvous({'t': 'commit', 'commit': session.commitPq()});
        _enterConversation();
        return;
      }

      _depositRendezvous({
        't': 'welcome',
        'name': _displayName,
        'welcome': invitation.welcome,
        'ratchetTree': invitation.ratchetTree,
      });

      for (final envelope in session.sealCommitForGroup(invitation.commit)) {
        _mailbox?.deposit(envelope);
      }

      // Spent, and written down. Counted after the commit rather than before,
      // so an admission that failed does not use up somebody's place.
      if (admittingTo != null) {
        admittingTo.meetingUses += 1;
        store.save(admittingTo);
      }

      // Our own tags moved with the epoch.
      _resubscribe();
      _stateChanges.add(state);
    } on Object catch (e) {
      if (founding) {
        _moveTo(RotelyxState.failed, error: 'could not admit $name: $e');
      } else {
        lastError = 'could not admit $name: $e';
        _stateChanges.add(state);
      }
    }
  }

  void _onConversation(String envelopeB64) {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return;

    final String payload;
    try {
      payload = session.openMine(envelopeB64, _config.lookback);
    } on Object {
      // Not addressed to us in this window. Ignore rather than react, because
      // reacting is itself a signal.
      //
      // Except in a note to self, where the envelope was deposited under the
      // other half's tag and so is genuinely not addressed to this one. It
      // arriving at all is the confirmation that the note went to the mailbox
      // and came back, so it is opened for that and then dropped: the copy on
      // screen was written when it was sent.
      _peerConfirm(envelopeB64);
      return;
    }

    try {
      final plaintext = session.receive(payload);

      // The group processed this and deliberately did not apply it.
      //
      // This has to be loud. A refusal means whoever sent it moved to a point
      // this device did not, so from here on their messages cannot be read.
      // Two ends at two points with nothing saying so is the exact failure
      // that cost a week of wrong diagnoses, and it used to reach here as
      // "a message failed to decrypt", which is untrue and which nobody sees.
      if (plaintext?.refused != null) {
        lastError = 'Somebody was added without a second member agreeing, so '
            'this device did not accept it. Whoever sent it has moved on and '
            'their messages will not arrive here until this is sorted out.';
        _notices.add(lastError!);

        // Not acknowledged. The envelope stays in the mailbox: this device did
        // not apply it, and releasing something that was refused would throw
        // away the only copy of the thing that has to be looked at.
        _stateChanges.add(state);
        return;
      }

      if (plaintext == null) {
        // A commit. The epoch moved, so our tags moved with it, listening on
        // the old set would go quiet with nothing saying why.
        //
        // Acknowledged here rather than below: MLS has consumed the commit and
        // this side is at the new epoch, so re-delivery would only be refused
        // as a replay and the envelope would sit until its TTL.
        // Somebody else moved the epoch, so this device owes nothing. A commit
        // is exactly what the debt was for: generations nothing has spent.
        // Answering one with a commit of its own is how two ends end up at two
        // epochs neither can leave. The engine clears its own flag on the same
        // reasoning; this is the half that stops us asking for it again.
        _rekeyOwed = false;

        // Written down before anything else. A commit is the largest move the
        // ratchet makes, and losing it meant reopening at the epoch before the
        // one this device is actually at. See `_useSession`.
        _persist();
        _acknowledge(envelopeB64);
        _resubscribe();
        _stateChanges.add(state);
        return;
      }
      // Blocked, and that is the end of it.
      //
      // Before the signal is read, before it is written down, before it is
      // counted or notified about or drawn on a widget or sent to a watch.
      // Most messengers block by receiving and then not showing, because the
      // address a message arrives at belongs to the account rather than to
      // the sender; here MLS authenticates the sending leaf, so the key is
      // known at exactly this point and nothing from them goes any further.
      //
      // The envelope is acknowledged, because the mailbox should let go of
      // something that has been dealt with, and refusing to read somebody is
      // dealing with it.
      final sender = plaintext.fromKey;
      if (sender != null && _isBlocked(sender)) {
        _acknowledge(envelopeB64);
        return;
      }

      final signal = Signal.decode(plaintext.text);
      if (signal != null) {
        // The author travels with it. A receipt says "I read up to here" and
        // in a group it matters a great deal which "I" that was.
        _onSignal(signal, from: plaintext.from);
        _persist();
        _acknowledge(envelopeB64);
        return;
      }

      // After `_emit`, which records and persists, so the mailbox is only told
      // to let go of something this device has written down.
      _emit(RotelyxMessage(text: plaintext.text, mine: false, at: DateTime.now()));
      _acknowledge(envelopeB64);
    } on Object catch (e) {
      // A genuine failure to open one, which is a different thing from the
      // group refusing to apply what it opened. Both used to land here and say
      // the same sentence.
      lastError = 'a message failed to decrypt: $e';
      _notices.add(lastError!);
      _stateChanges.add(state);
    }
  }

  /// Tell the mailbox an envelope arrived, so it can stop holding it.
  ///
  /// Called only on the paths that processed one: a commit applied, a signal
  /// acted on, a message recorded and persisted. Never on the path where
  /// opening failed, because an envelope that is not ours to read is not ours
  /// to release.
  ///
  /// Best effort. A receipt that does not arrive means re-delivery, which MLS
  /// refuses as a replay, so the cost is battery rather than correctness. The
  /// other direction, acknowledging something unstored, loses a message, which
  /// is why this is never called before the write.
  void _acknowledge(String envelopeB64) {
    try {
      _mailbox?.collected([RotelyxWasm.receiptFor(envelopeB64)]);
    } on Object {
      // See above: re-delivery is the recoverable failure and it is this one.
    }
  }

  /// Display labels of the current members. Claims, not identities.
  List<String> get roster {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return const [];
    try {
      return session.roster();
    } on Object {
      return const [];
    }
  }

  /// Everyone here, each with the key that identifies them.
  ///
  /// [roster] gives labels, which two members can both claim. Removing takes a
  /// key, so anything offering removal has to read this one.
  List<({String label, String key})> get members {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return const [];
    try {
      final raw = jsonDecode(session.rosterDetail()) as List;
      return [
        for (final m in raw.cast<Map<String, dynamic>>())
          (label: m['label'] as String, key: m['key'] as String),
      ];
    } on Object {
      return const [];
    }
  }

  /// The members allowed to turn a request into a member, by the labels the
  /// roster uses. Empty when the conversation allows everybody.
  ///
  /// This narrows who may decide. It never narrows who may ask: an ordinary
  /// member proposing somebody is what a request to join looks like from
  /// inside the group, and it stays available to everybody.
  List<String> get admins {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return const [];
    try {
      return session.admins();
    } on Object {
      return const [];
    }
  }

  /// Whether the rule is actually running, rather than merely written down.
  ///
  /// A list whose people have all left is a conversation that could otherwise
  /// never admit anybody again, and there is no server here to be asked to fix
  /// that, so the engine stands the rule down and this says so rather than
  /// showing a rule the group is not under.
  bool get adminRuleIsRunning {
    final named = admins;
    if (named.isEmpty) return false;
    final here = members.map((m) => m.label).toSet();
    return named.any(here.contains);
  }

  /// Name the members allowed to let people in. An empty list turns it off.
  ///
  /// Anybody in the conversation can do this, and the reason is the same as
  /// everywhere else here: there is nobody above the members to authorise it.
  /// What stops it being abused is that the commit is visible, so a member
  /// quietly making itself the only one who decides is a change everybody
  /// watches arrive.
  Future<bool> setAdmins(List<String> labels) async {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return false;

    try {
      final commit = session.setAdmins(labels);

      // At the epoch the others are still on, because this commit is what
      // moves them off it. The same trap the invitation path documents.
      for (final envelope in session.sealCommitForGroup(commit)) {
        _mailbox?.deposit(envelope);
      }
      session.settle();
      _persist();
      _resubscribe();
      _stateChanges.add(state);
      return true;
    } on Object catch (e) {
      lastError = 'could not change who lets people in: $e';
      _notices.add(lastError!);
      _stateChanges.add(state);
      return false;
    }
  }

  /// Put a member out of the conversation.
  ///
  /// This is how a lost or stolen device is revoked, and until 29 August 2026
  /// the phone could not do it at all: the engine had it, the C ABI did not,
  /// so the browser and the desktop could revoke and the device most likely to
  /// be lost could not.
  ///
  /// A removal is a commit. Everybody who applies it moves to an epoch derived
  /// without that leaf, which is what makes it real rather than a local note,
  /// and what makes it visible to the removed device instead of something it
  /// could ignore. It does not reach backwards: what that member could already
  /// read, it keeps.
  ///
  /// The commit is addressed at the epoch the others are still on, because that
  /// commit is what moves them off it. Sending it at the new epoch would
  /// deposit under tags nobody is listening on and split the group silently,
  /// which is the same trap the invitation path documents.
  Future<bool> removeMember(String signatureKeyB64) async {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return false;

    try {
      final commit = session.removeMember(signatureKeyB64);
      for (final envelope in session.sealCommitForGroup(commit)) {
        _mailbox?.deposit(envelope);
      }

      // Applied once every copy is deposited. Two people reaching for the same
      // removal at the same moment is not contrived, and until this line runs
      // this device can still take theirs instead of its own.
      session.settle();

      // Our own tags moved with the epoch, as they do after any commit.
      _resubscribe();
      _stateChanges.add(state);
      return true;
    } on Object catch (e) {
      lastError = 'could not remove that member: $e';
      _stateChanges.add(state);
      return false;
    }
  }

  /// What to call this conversation, from the labels its members chose.
  ///
  /// A conversation had no name at all: the pairing screen titled it after the
  /// meeting phrase, and a QR pairing has no phrase, so every conversation
  /// started from a code was called "Conversation". The other side's name was
  /// known the whole time, sent in the rendezvous and carried in the MLS
  /// credential, and nothing was reading it.
  ///
  /// Returns null before the group exists, so a caller can tell "not yet" from
  /// "nobody said".
  ///
  /// These are claims and not identities. The safety number is what verifies,
  /// which is why it sits beside the name rather than behind a menu.
  /// The conversation this service is persisting to, if any.
  String? get conversationId => _persistId;

  /// The live session, for a call to key from.
  ///
  /// Exposed for exactly one caller. A call derives its per-sender keys from
  /// the group secret, so it needs the session rather than a copy of anything:
  /// the whole reason a call is as protected as a message is that they come
  /// from the same place.
  WasmSession? get session => _session;

  String? get conversationName {
    final others = roster.where((name) => name != _displayName).toList();
    if (others.isEmpty) return null;
    if (others.length == 1) return others.first;
    if (others.length == 2) return '${others.first} and ${others.last}';
    return '${others.first} and ${others.length - 1} others';
  }

  /// The label this device is using. Shown so a user can see what the other
  /// side sees.
  String get displayName => _displayName;

  /// Say what this person looks like, once per conversation per run.
  ///
  /// Nothing is sent when no picture has been chosen, which is the ordinary
  /// case: both ends draw the same initials from the same name and there is
  /// nothing to carry.
  void _sendMyPicture() {
    final id = _persistId;
    final picture = store.myPicture;
    if (id == null || picture == null || picture.isEmpty) return;
    if (!_toldMyPicture.add(id)) return;
    signal(Signal.profile(picture));
  }

  void _enterConversation() {
    // A guest stops listening at the meeting place; the host does not.
    //
    // The host stays so people can arrive later. Collection removes, so a guest
    // still listening would swallow a knock meant for the host, and the
    // newcomer would wait forever with nothing on screen.
    final meeting = _meetingTag;
    if (meeting != null && _role == PairingRole.guest) {
      _mailbox?.unsubscribe([meeting]);
    }

    // `_meetingTag` is deliberately **not** cleared.
    //
    // The host deposits the welcome and the post-quantum commit back to back,
    // so the commit is already in flight when the guest processes the welcome
    // and lands here. Unsubscribing is a frame sent to the server; it does not
    // recall what the server already pushed. Clearing the tag would leave
    // `_onEnvelope` unable to recognise that commit as rendezvous traffic, so
    // it would fall through to `_onConversation`, fail the tag check there, and
    // be dropped in silence, leaving the guest an epoch behind with the
    // post-quantum secret never mixed into the key schedule, and no error
    // anywhere. The only visible symptom would be safety numbers that disagree.
    _moveTo(RotelyxState.joined);

    // The invitation has been used. Forgotten here rather than left to expire,
    // because a meeting somebody has already arrived at is a place this
    // application would otherwise go on listening at after every launch, for
    // as long as the invitation was good for.
    //
    // The envelope the guest deposited is removed separately, by the mailbox's
    // own `collected`: delivery does not remove, so that a tag anybody can
    // derive cannot be drained by somebody who is not the recipient.
    store.forgetWaiting();

    // From here messages travel under tags derived from the group itself, not
    // from the meeting phrase. Anyone who knew the phrase loses the thread.
    _resubscribe();
    _watchTagRotation();

    // And what this person looks like, to somebody who has just met them.
    _sendMyPicture();
  }

  /// Listen on our own tags for the current window.
  ///
  /// Only the tags not already subscribed to are sent. Re-subscribing to a tag
  /// already held is harmless on the wire but makes the epoch-change path
  /// re-send the whole set every commit, which is the burst an operator would
  /// most like to see.
  void _resubscribe() {
    final session = _session;
    if (session == null) return;

    final now = session.myPollingTags(_config.lookback).toSet();

    // In a note to self the deposit lands under the other half's tag, so this
    // device has to be listening on both or its own note never comes back.
    final peer = _selfPeer;
    if (peer != null) {
      try {
        now.addAll(peer.myPollingTags(_config.lookback));
      } on Object {
        // A half that cannot name its tags yet contributes none. The primary
        // set is still correct, so this is not worth failing over.
      }
    }

    final fresh = now.difference(_listening).toList();
    if (fresh.isNotEmpty) {
      _mailbox?.subscribe(fresh);
      _leaveTicketsFor(fresh);
      _listening.addAll(fresh);
    }
    _subscribedBucket = _bucket();
    unawaited(_publishTagsForTheExtension());
  }

  /// Leave a wake ticket under each tag just subscribed to.
  ///
  /// # What this buys
  ///
  /// A message that arrives while this device is asleep wakes it at once
  /// rather than at the next sweep of the mailbox's schedule. Without a ticket
  /// the schedule is all there is, and the interval is the delay.
  ///
  /// # What it costs, which is nothing that can be followed
  ///
  /// A ticket is this device's push token sealed to the notifier's key. The
  /// mailbox holds it and cannot read it, and because each one is sealed on
  /// its own they share no bytes: holding one under every tag this device
  /// listens on gives the mailbox rows with nothing in common. The notifier
  /// can read a ticket and is never told which tag it came from.
  ///
  /// Skipped in silence when there is no notifier configured, no push token
  /// yet, or the engine cannot seal one. Every one of those is a device that
  /// falls back to the schedule, which is a slower wake and not a broken one,
  /// and none of them is worth interrupting somebody about.
  void _leaveTicketsFor(List<String> tags) {
    final notifier = _config.notifierKey;
    final token = _wakeToken;
    final session = _session;
    if (notifier == null || token == null || session == null) return;

    // The same name the registration uses. A ticket that named a different
    // service would be opened and then handed to a provider that has never
    // heard of the token.
    const kind = PushGrant.defaultKind;

    // The same bucket the addresses use, from the same constant. A ticket
    // sealed for a different bucket than the tag it sits under is a wake that
    // never fires, and nothing reports it.
    final hour =
        DateTime.now().millisecondsSinceEpoch ~/ (tagBucketSeconds * 1000);
    final byTag = <String, String>{};

    for (final tag in tags) {
      try {
        byTag[tag] = RotelyxWasm.sealWakeTicket(notifier, kind, token, hour);
      } on Object {
        // One tag that could not be sealed for is one tag woken on the
        // schedule. The rest are still worth leaving.
      }
    }

    if (byTag.isNotEmpty) _mailbox?.leaveTickets(byTag);
  }

  /// Write the tags being listened on where the notification extension can
  /// read them.
  ///
  /// # Why the extension needs them
  ///
  /// A push carries nothing, deliberately: a payload with the message in it is
  /// a message handed to Apple. So the extension has to find out for itself
  /// whether anything actually arrived, and to ask the mailbox that it needs
  /// to name the tags to ask about.
  ///
  /// Without this it cannot ask, and it did the only thing left: show a
  /// notification for every wake. Since the mailbox wakes on a schedule
  /// whether or not anything arrived, that is a notification every few minutes
  /// saying nothing, which is what a person actually holding the phone sees.
  ///
  /// # What is written, and what is not
  ///
  /// The tags, which are what the mailbox already sees on every subscription,
  /// and nothing else. No keys, no message, no name. A tag is a rotating
  /// pseudonym that says nothing on its own, and this file sits in a container
  /// only this application and its own extension can open.
  Future<void> _publishTagsForTheExtension() async {
    if (_listening.isEmpty) return;
    try {
      await publishListeningTags(_config.mailbox, _listening.toList());
    } on Object {
      // A phone whose extension cannot be told is a phone that shows the
      // notification it would have shown before. Worth no interruption.
    }
  }

  /// Move a restored session to an epoch of its own, and tell the others.
  ///
  /// # Why the commit goes to the old epoch
  ///
  /// This commit is what moves the others off the epoch they are on, so it has
  /// to be addressed there. Sent at the new one it lands under tags nobody is
  /// listening on, and the group splits with this device an epoch ahead and
  /// nothing saying so. `sealCommitForGroup` addresses one epoch back for
  /// exactly this reason, which is why it and not `sealForGroup`.
  ///
  /// # Why a failure here is not fatal
  ///
  /// A conversation with one member has nobody to tell and nothing to move, and
  /// a note to self is the ordinary case of that. Failing the conversation over
  /// it would make history unreadable to protect a rekey nobody needed.
  /// Pay the debt if one is owed, before this device sends anything.
  ///
  /// Public because placing a call sends through [signal], and [signal] cannot
  /// pay it itself: read receipts go out through there too, and they are sent
  /// on merely opening a conversation, which is the thing this whole change
  /// exists to stop being a commit.
  void rekeyIfOwed() {
    if (!_rekeyOwed) return;
    _rekeyOwed = false;
    _rekeyAfterRestore();
  }

  void _rekeyAfterRestore() {
    final session = _session;
    if (session == null) return;

    try {
      final commit = session.rekeyAfterRestore();
      for (final envelope in session.sealCommitForGroup(commit)) {
        _mailbox?.deposit(envelope);
      }

      // Applied once every copy is in the mailbox, and not a line earlier.
      //
      // This is the one that cost a week. Two devices reopening at the same
      // moment each used to apply its own fresh key immediately, and then
      // neither could ever process the other's: not a dropped message, two
      // conversations where there was one. Between the deposit above and this
      // line, this device is still standing where the other one is, so if
      // theirs arrives it can be taken instead and both end up in the same
      // place.
      session.settle();

      // The tags moved with the epoch, as they do after any commit, so what
      // this device listens on has to move with them.
      _resubscribe();
    } on Object catch (e) {
      // Recorded rather than raised. What it costs is sending, which the next
      // attempt will refuse loudly on its own, and what raising would cost is
      // the conversation.
      lastError = 'this conversation could not take a fresh key: $e';
    }
  }

  /// Re-subscribe when the hour rolls over.
  ///
  /// Mailbox tags are derived from the hour bucket, so the set subscribed to at
  /// pairing time stops matching what the other side deposits under as soon as
  /// the hour changes. Without this the conversation goes quiet at the top of
  /// the hour and stays quiet, which reads as the other person having left.
  ///
  /// The check is cheap and the lookback window covers the boundary, so polling
  /// every minute is far more slack than needed.
  void _watchTagRotation() {
    _rotation?.cancel();
    _rotation = Timer.periodic(const Duration(minutes: 1), (_) {
      if (state != RotelyxState.joined) return;
      if (_bucket() != _subscribedBucket) _resubscribe();
    });
  }

  /// Hours since the Unix epoch, the same formula the wasm bridge uses.
  int _bucket() => DateTime.now().millisecondsSinceEpoch ~/ 3600000;

  // -------------------------------------------------------------------------
  // Outgoing
  // -------------------------------------------------------------------------

  /// Encrypt once, then deposit one copy per recipient.
  ///
  /// Each copy is addressed to that member's own tag. This is what a group
  /// costs: the operator sees a burst of deposits from one connection and can
  /// count us. A single shared tag would be cheaper and would deliver each
  /// message to exactly one member, because collection removes.
  bool send(String text) {
    final session = _session;
    if (session == null || state != RotelyxState.joined) return false;
    if (text.trim().isEmpty) return false;

    // Before the first word this device says, and never for merely opening.
    rekeyIfOwed();

    final message =
        RotelyxMessage(text: text, mine: true, at: DateTime.now(),
            delivery: Delivery.sending);

    try {
      final ciphertext = session.send(text);
      final envelopes = session.sealForGroup(ciphertext);
      _pending[message] = envelopes.length;
      for (final envelope in envelopes) {
        _mailbox?.deposit(envelope);
      }
    } on Object catch (e) {
      lastError = 'could not send: $e';
      message.delivery = Delivery.refused;
      return false;
    }

    _emit(message);
    return true;
  }

  void _depositRendezvous(Map<String, Object?> payload) {
    final meeting = _meetingTag;
    if (meeting == null) return;
    _depositAt(meeting, payload);
  }

  /// Leave something at a meeting place that is not ours.
  ///
  /// Used when confirming somebody else's addition: the person knocking is
  /// listening at the asking member's meeting place, and this device has no
  /// way to work that address out for itself. It travels in the request.
  void _depositAt(String tagHex, Map<String, Object?> payload) {
    final encoded = base64Encode(utf8.encode(jsonEncode(payload)));
    _mailbox?.deposit(RotelyxWasm.sealUnder(tagHex, encoded));
  }

  /// 32 random bytes as hex, the shape `sealUnder` expects.
  String _randomTag() {
    final rng = Random.secure();
    return List.generate(32, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// The conversation with yourself, which has a fixed id rather than a minted
  /// one so that every part of the app can name it without being told.
  static const selfConversationId = 'self';

  /// Open the conversation with yourself, founding it if this is the first time.
  Future<bool> startNoteToSelf() => resume(selfConversationId);

  /// Where the second half of a note to self is kept.
  ///
  /// A derived id rather than a new column, because `saveSession` already takes
  /// any string and this needs no change to the store to sit beside its own
  /// conversation and be removed with it.
  static String _peerId(String conversationId) => '$conversationId.peer';

  /// Open the conversation with yourself, founding it the first time.
  ///
  /// The handshake happens entirely in this process: no meeting code, no
  /// rendezvous tag, nobody to wait for. Both key packages are to hand, so they
  /// are exchanged directly the way `test/note_to_self_test.dart` does it.
  Future<bool> _foundNoteToSelf(String conversationId) async {
    final key = store.key;

    final a = RotelyxWasm.newSession(_displayName);
    final b = RotelyxWasm.newSession(_displayName);

    try {
      a.found();
      final invitation = a.invite(b.keyPackage());
      b.join(invitation.welcome, invitation.ratchetTree);

      // The post-quantum layer, settled before anything is sent, exactly as a
      // pairing with another person settles it.
      b.openPq(a.encapsulateTo(b.hybridPublicKey()));
      b.receive(a.commitPq());
    } on Object catch (e) {
      a.dispose();
      b.dispose();
      _moveTo(RotelyxState.failed,
          error: 'the conversation with yourself could not be started: $e');
      return false;
    }

    _useSession(a);
    _usePeer(b);
    _persistId = conversationId;
    _role = PairingRole.host;
    _listening.clear();

    // The row in the list, written on first open rather than at install, so a
    // device nobody has used yet does not show a conversation nobody started.
    if (store.load(conversationId) == null) {
      store.save(StoredConversation(
        id: conversationId,
        title: 'Notes to myself',
        session: null,
        messages: [],
        lastActivity: DateTime.now(),
      ));
    }

    // Sealed now rather than on the first note, so that quitting before writing
    // anything does not leave a founded group with no way back to it.
    if (key != null) {
      store.saveSession(conversationId, a);
      store.saveSession(_peerId(conversationId), b);
    }

    try {
      await _openMailbox();
    } on Object {
      // No mailbox is not fatal here. Notes are written locally as they are
      // sent, so the conversation works offline and starts travelling once
      // there is somewhere to travel to.
      _moveTo(RotelyxState.joined);
      return true;
    }

    _moveTo(RotelyxState.joined);
    _resubscribe();
    _watchTagRotation();
    return true;
  }

  /// Bring a stored conversation back to life.
  ///
  /// This is what makes the app usable rather than a demo: without it, every
  /// restart is a new identity and a new group, and the history on disk belongs
  /// to a conversation that no longer exists.
  ///
  /// The sealed blob carries the MLS state, so the restored session is the same
  /// member at the same epoch. What it does not carry is a mailbox connection,
  /// so the socket is reopened and the member's tags re-subscribed, tags are
  /// derived from the group key and the hour, so they are recomputed rather
  /// than stored.
  Future<bool> resume(String conversationId) async {
    final key = store.key;
    final blob = store.sessionBlob(conversationId);

    // The conversation with yourself is founded on first open rather than
    // paired into existence, so there is nothing sealed the first time and that
    // is not a failure. Handled here so that every caller of `resume`, and
    // there are three, needs to know nothing about it.
    if (blob == null && conversationId == selfConversationId) {
      return _foundNoteToSelf(conversationId);
    }

    if (key == null || blob == null) return false;

    // Already in memory, so there is nothing to read back.
    //
    // Only one conversation is live at a time, and `resume` used to unseal
    // unconditionally. So leaving a conversation and coming back to it, or
    // coming back after a dropped connection, read the session off the disk
    // again and marked a fresh key as owed, even though the very same session
    // was sitting in memory untouched. Every switch between two conversations
    // was an epoch, on both phones, and two phones that moved epoch without
    // seeing each other never met again.
    //
    // Reusing it leaves a cold start as the only thing that unseals, which is
    // the only case where a copy really can be behind.
    final reusing = _persistId == conversationId && _session != null;

    if (!reusing) {
      try {
        _useSession(RotelyxWasm.unsealSession(blob, key));
      } on Object catch (e) {
        _moveTo(RotelyxState.failed,
            error: 'this conversation could not be reopened: $e');
        return false;
      }
    }

    // A note to self sealed two halves. Both come back or neither does: with
    // only the sending half the group still works, but its own notes are
    // deposited under a tag nothing on this device is listening to.
    if (!reusing) _usePeer(null);
    final peerBlob = reusing ? null : store.sessionBlob(_peerId(conversationId));
    if (peerBlob != null) {
      try {
        _usePeer(RotelyxWasm.unsealSession(peerBlob, key));
      } on Object catch (e) {
        _moveTo(RotelyxState.failed,
            error: 'this conversation could not be reopened: $e');
        return false;
      }
    }

    _persistId = conversationId;
    _role = PairingRole.host;
    _listening.clear();

    // Back to the meeting place, when this device is the one that answers
    // there. `_resubscribe` below covers the conversation's own tags and knew
    // nothing about this one, so after a restart the host had stopped
    // listening where the phrase points and a newcomer knocked at nobody.
    _meetingTag = store.load(conversationId)?.meetingTag;

    try {
      await _openMailbox();
    } on Object {
      return false;
    }

    _moveTo(RotelyxState.joined);
    _resubscribe();

    // Contacts paired before this person chose a picture, and contacts who
    // were not listening when they changed it. Once per conversation per run.
    _sendMyPicture();

    // A session that came off the disk owes the group a fresh key before it
    // can send, and the debt is *recorded* here rather than paid. One that was
    // never read back owes nothing: it is the same session, at the same
    // generation, and moving its epoch would be the defect rather than the fix.
    //
    // # Why not here
    //
    // Paying it here meant a commit on every reopen, and a reopen happens on
    // every application start and after every dropped connection. Two phones
    // doing that without seeing each other each moved to an epoch of their own,
    // and two commits made at the same epoch cannot both be accepted: one side
    // is refused and stays behind. From then on each deposits under tags the
    // other is not listening on, and no amount of closing and reopening brings
    // them back, because what is broken is the conversation and not the socket.
    //
    // A device that opens a conversation and reads it now changes nothing. The
    // debt is paid by the first thing this device actually sends, which is the
    // moment the fresh key is genuinely needed, and that is one commit for a
    // person who says something rather than one for a person who looked.
    if (reusing) {
      // Never left memory, so there is nothing to vouch for and nothing owed.
    } else if (store.sessionSealedClean(conversationId)) {
      // Sealed after the last thing that moved it, and nothing has used it
      // since. It may send where it is, and the epoch stays put: moving it is
      // what leaves two phones unable to find each other.
      try {
        _session?.trustRestoredState();
      } on Object {
        _rekeyOwed = true;
      }
    } else {
      // Killed while live, or from before any of this. One rekey, once.
      _rekeyOwed = true;
    }

    // In use from here, so it can no longer be vouched for until it is sealed
    // again. An application killed after this point comes back and rekeys.
    store.setSessionSealedClean(conversationId, false);

    final meeting = _meetingTag;
    if (meeting != null) {
      _mailbox?.subscribe([meeting]);

      // And a wake ticket there, so somebody knocking reaches this device even
      // with the application closed.
      //
      // # Why this does not link the conversations
      //
      // Listening at every conversation's meeting place at once would, and was
      // built and taken out for it: one connection naming several
      // conversations' addresses tells the mailbox they belong to one device.
      //
      // A ticket is different in the one way that matters here. It is left
      // **while this conversation is the live one**, in a request that names
      // this conversation's addresses and no others, so the mailbox never sees
      // two of them together. And two tickets from one device share no bytes,
      // which is what `WakeTicket` was built for: the mailbox stores them,
      // hands them on, and cannot tell that any two are related.
      //
      // So the notification arrives without anybody having to be looking, and
      // the mailbox learns nothing it did not already know about this one
      // conversation.
      _leaveTicketsFor([meeting]);
    }

    // Opened, so it stops being a conversation somebody is waiting outside of.
    // The knock itself was never acknowledged, so the mailbox still has it and
    // re-delivers it here, where the ordinary rendezvous path admits.


    _watchTagRotation();
    return true;
  }

  /// Bind this live session to a stored conversation, so the MLS state is
  /// sealed after every send and every receive. The ratchet turns on both, and
  /// a blob one message behind cannot decrypt what arrives next.
  void persistTo(String conversationId) {
    _persistId = conversationId;
    _persist();

    // The meeting tag is written down here rather than left in a field,
    // because the host answers knocks for the life of the conversation and a
    // field does not survive the application being closed. Without this the
    // phrase quietly stopped working after a restart: the newcomer knocked,
    // nobody was listening where the phrase points, and neither side was told.
    //
    // Host only. A guest unsubscribes from the meeting place on the way in so
    // as not to swallow a knock meant for the host, and writing down a tag it
    // does not listen on would be a note that means nothing.
    final meeting = _meetingTag;
    if (meeting != null && _role == PairingRole.host) {
      // With the deadline the person chose when they handed the invitation out.
      //
      // It was written beside the waiting invitation and thrown away the moment
      // the conversation existed, so a phrase meant to last an hour went on
      // opening the door for ever. The waiting record still has it here,
      // because this runs while the pairing is being finished.
      final held = store.waiting;
      final until = held != null && held['until'] is int
          ? DateTime.fromMillisecondsSinceEpoch(held['until'] as int)
          : null;
      store.rememberMeetingTag(conversationId, meeting, until: until);
    }
  }

  String? _persistId;

  void _persist() {
    final id = _persistId;
    final session = _session;
    if (id == null || session == null) return;
    store.saveSession(id, session);
    // Written down after the thing that moved it, which is what lets the next
    // reopen send without moving the epoch. See `RotelyxStore.sessionSealedClean`.
    store.setSessionSealedClean(id, true);
  }

  Future<void> dispose() async {
    _rotation?.cancel();
    for (final listener in _mailboxListeners) {
      await listener.cancel();
    }
    _mailboxListeners.clear();
    await _mailbox?.close();
    _useSession(null);
    _usePeer(null);
    await _messages.close();
    await _stateChanges.close();
    await _notices.close();
  }
}


/// The one live conversation this tab holds.
///
/// One instance, not one per screen: the MLS group lives in wasm memory, so a
/// second service would be a second identity and the first conversation would
/// quietly stop receiving.
final rotelyx = RotelyxService();
