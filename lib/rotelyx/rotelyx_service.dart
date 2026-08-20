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

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'burn_clock.dart';
import 'mailbox_client.dart';
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

class RotelyxService {
  RotelyxService({RotelyxConfig config = rotelyxConfig}) : _config = config;

  final RotelyxConfig _config;

  WasmSession? _session;
  MailboxClient? _mailbox;
  String? _meetingTag;
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

  /// Replace the live session, releasing whatever it replaces.
  ///
  /// A browser collects a discarded session; the native engine keeps it in a
  /// registry until told otherwise. Every path that abandons one comes through
  /// here so that neither platform needs the caller to remember which it is on.
  void _useSession(WasmSession? next) {
    final previous = _session;
    if (identical(previous, next)) return;
    _session = next;
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
  void _onSignal(Signal signal) {
    switch (signal.kind) {
      case SignalKind.burnRead:
        _theyRead(signal.burnIds);
      case SignalKind.read:
        _theySawUpTo(signal.readThrough);
      case SignalKind.reaction:
        _theyReacted(signal);
      case SignalKind.profile:
        _theyChangedPicture(signal.picture);
      case SignalKind.call:
        // Ringing, answering, hanging up. Passed straight out rather than
        // acted on here: whether a call may start is a question about what is
        // on screen, and this object has no idea what is on screen.
        _calls.add(signal);
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
  void _theySawUpTo(DateTime through) {
    _rewrite((messages) {
      var changed = false;
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        if (!m.mine || m.seen) continue;
        if (m.at.isAfter(through)) continue;
        messages[i] = m.copyWith(seen: true);
        changed = true;
      }
      return changed;
    });
  }

  /// Add or remove a reaction on one of our messages.
  void _theyReacted(Signal signal) {
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
        final who = conversationName ?? 'They';
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

  /// Keep the picture they sent.
  void _theyChangedPicture(Uint8List? picture) {
    final id = _persistId;
    if (id == null || picture == null || picture.isEmpty) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    conversation.picture = picture;
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

    final started = onRead(conversation.messages);
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
  Future<bool> askToBeWoken() async {
    if (!canBeWoken) return false;

    final token = await pushTransport.obtainToken();
    if (token == null) return false;

    _wakeToken = token;
    if (state == RotelyxState.joined) {
      _mailbox?.registerWake(
          PushGrant(token: token, secret: store.wakeSecret));
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
            PushGrant(token: token, secret: store.wakeSecret));
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
  }) async {
    _displayName = displayName;
    _role = role;
    _meetingTag = RotelyxWasm.rendezvousTag(phrase);
    await _startPairing();
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
  }) =>
      pairByPhrase(phrase: code, displayName: displayName, role: role);

  /// Generate an invitation this device is waiting on, to be delivered out of
  /// band by paste.
  ///
  /// The code carries a key package, a hybrid public key, and a random return
  /// tag. All three are public. The return tag is 32 random bytes rather than a
  /// phrase, so unlike [pairByPhrase] there is nothing to guess, but the code
  /// still authenticates nobody, and the safety number is still the only check
  /// that matters.
  Future<String> createInvitation({required String displayName}) async {
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

  Future<void> _startPairing() async {
    final session = RotelyxWasm.newSession(_displayName);
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

    final mailbox = MailboxClient(_config.mailbox);
    _mailbox = mailbox;

    _mailboxListeners.add(mailbox.envelopes.listen(_onEnvelope));
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
      if (state != RotelyxState.joined) {
        _moveTo(RotelyxState.failed, error: message);
      }
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

    try {
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
      return;
    }

    try {
      final plaintext = session.receive(payload);
      if (plaintext == null) {
        // A commit. The epoch moved, so our tags moved with it, listening on
        // the old set would go quiet with nothing saying why.
        _resubscribe();
        _stateChanges.add(state);
        return;
      }
      final signal = Signal.decode(plaintext);
      if (signal != null) {
        _onSignal(signal);
        return;
      }

      _emit(RotelyxMessage(text: plaintext, mine: false, at: DateTime.now()));
    } on Object catch (e) {
      lastError = 'a message failed to decrypt: $e';
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

    // From here messages travel under tags derived from the group itself, not
    // from the meeting phrase. Anyone who knew the phrase loses the thread.
    _resubscribe();
    _watchTagRotation();
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

    final now =
        session.myPollingTags(_config.lookback).toSet();
    final fresh = now.difference(_listening).toList();
    if (fresh.isNotEmpty) {
      _mailbox?.subscribe(fresh);
      _listening.addAll(fresh);
    }
    _subscribedBucket = _bucket();
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
    final encoded = base64Encode(utf8.encode(jsonEncode(payload)));
    _mailbox?.deposit(RotelyxWasm.sealUnder(meeting, encoded));
  }

  /// 32 random bytes as hex, the shape `sealUnder` expects.
  String _randomTag() {
    final rng = Random.secure();
    return List.generate(32, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
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
    if (key == null || blob == null) return false;

    try {
      _useSession(RotelyxWasm.unsealSession(blob, key));
    } on Object catch (e) {
      _moveTo(RotelyxState.failed,
          error: 'this conversation could not be reopened: $e');
      return false;
    }

    _persistId = conversationId;
    _role = PairingRole.host;
    _listening.clear();

    try {
      await _openMailbox();
    } on Object {
      return false;
    }

    _moveTo(RotelyxState.joined);
    _resubscribe();
    _watchTagRotation();
    return true;
  }

  /// Bind this live session to a stored conversation, so the MLS state is
  /// sealed after every send and every receive. The ratchet turns on both, and
  /// a blob one message behind cannot decrypt what arrives next.
  void persistTo(String conversationId) {
    _persistId = conversationId;
    _persist();
  }

  String? _persistId;

  void _persist() {
    final id = _persistId;
    final session = _session;
    if (id == null || session == null) return;
    store.saveSession(id, session);
  }

  Future<void> dispose() async {
    _rotation?.cancel();
    for (final listener in _mailboxListeners) {
      await listener.cancel();
    }
    _mailboxListeners.clear();
    await _mailbox?.close();
    _useSession(null);
    await _messages.close();
    await _stateChanges.close();
  }
}


/// The one live conversation this tab holds.
///
/// One instance, not one per screen: the MLS group lives in wasm memory, so a
/// second service would be a second identity and the first conversation would
/// quietly stop receiving.
final rotelyx = RotelyxService();
