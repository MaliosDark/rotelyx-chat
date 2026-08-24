/// Local, encrypted storage. The only copy that exists.
///
/// # Why this file matters more than it looks
///
/// The mailbox keeps nothing: an envelope is removed when it is collected, and
/// what is never collected expires. There is no server-side history, no account
/// to restore from, and no other device holding a copy unless the user made
/// one. If this store loses a conversation, the conversation is gone.
///
/// That is the cost of a design where the operator knows nothing, and it is the
/// right trade, but it makes durability a feature, not an afterthought.
///
/// # What is written, and how
///
/// Two blobs per conversation, both sealed under a key derived from the user's
/// passphrase with Argon2id at 64 MiB:
///
///   - **the session**, which is MLS group state. Re-sealed after every send
///     and every receive, because the ratchet turns on both and a blob one
///     message stale cannot decrypt what comes next.
///   - **the log**, which is readable message text.
///
/// The second one is the significant one. Everywhere else in Rotelyx plaintext
/// exists only in memory, for the moment it is on screen. A conversation kept
/// across restarts is a conversation written down, encrypted, but written
/// down, in a profile directory that can be copied. That is a real change to
/// the threat model, which is why keeping history is **opt in** and why turning
/// it on asks for a passphrase rather than inventing one.
///
/// Without a passphrase the app still works. It simply forgets on reload, which
/// is the stronger position and the wrong default for a messenger people are
/// meant to use daily.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:get_storage/get_storage.dart';

import 'ephemeral.dart';
import 'chat_lock.dart' as chat_lock;
import 'rotelyx_wasm.dart';

/// One stored message.
class StoredMessage {
  const StoredMessage({
    required this.text,
    required this.mine,
    required this.at,
    this.author = '',
    this.inMailbox = true,
    this.seen = false,
    this.seenBy = const [],
    this.edited = false,
    this.reactions = const {},
    this.burnAt,
  });

  final String text;
  final bool mine;
  final DateTime at;

  /// Whether the mailbox accepted it. Absent for received messages.
  final bool inMailbox;

  /// The sender's chosen label. Empty for our own messages.
  final String author;

  /// Whether the other side has said they read it.
  ///
  /// Only ever true for our own messages, and only when the other side has
  /// receipts switched on. Nothing infers this: absence means "they did not
  /// say", not "they did not read", and the interface has to say so or it is
  /// inventing a fact about somebody.
  ///
  /// In a group this means **everybody** in [seenBy] has said so, which is what
  /// a double tick is taken to mean. Anything less is [seenBy] on its own.
  final bool seen;

  /// Whether this was changed after it was sent.
  ///
  /// Shown, always. The previous text is not kept anywhere, which is the point
  /// of an edit here, so this mark is the only thing that says it happened, and
  /// removing it would let somebody quietly rewrite what they said.
  final bool edited;

  /// Who has said they read it, by the label they chose.
  ///
  /// Empty in a conversation of two, where [seen] carries the whole answer and
  /// a list of one name is noise. A group of eight is the case this exists for:
  /// "somebody read it" and "everybody read it" are different facts, and a tick
  /// that means the first while looking like the second is the kind of small
  /// lie that gets believed.
  final List<String> seenBy;

  /// Emoji to the people who sent them. Empty for the overwhelming majority.
  final Map<String, List<String>> reactions;

  /// When this message destroys itself, once the countdown has started.
  ///
  /// Null means either that it does not expire, or that it does and has not
  /// been read yet. The two are told apart by asking the body, because a
  /// deadline is set the moment somebody sees it.
  ///
  /// A deadline rather than a remaining duration, so that closing the
  /// application does not pause the clock. Somebody who set a message to go in
  /// a minute meant a minute, not a minute of screen time.
  final DateTime? burnAt;

  /// True once the deadline has passed.
  bool get burnt =>
      burnAt != null && DateTime.now().isAfter(burnAt!);

  /// How long is left, or null when nothing is counting.
  Duration? get burnIn {
    final at = burnAt;
    if (at == null) return null;
    final left = at.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// A copy with fields replaced. The class is immutable, so an update to a
  /// message is a new message in its place.
  StoredMessage copyWith({
    String? text,
    bool? inMailbox,
    bool? seen,
    List<String>? seenBy,
    bool? edited,
    Map<String, List<String>>? reactions,
    DateTime? burnAt,
  }) =>
      StoredMessage(
        text: text ?? this.text,
        mine: mine,
        at: at,
        author: author,
        inMailbox: inMailbox ?? this.inMailbox,
        seen: seen ?? this.seen,
        seenBy: seenBy ?? this.seenBy,
        edited: edited ?? this.edited,
        reactions: reactions ?? this.reactions,
        burnAt: burnAt ?? this.burnAt,
      );

  Map<String, dynamic> toJson() => {
        't': text,
        'm': mine,
        'a': at.millisecondsSinceEpoch,
        if (author.isNotEmpty) 'w': author,
        if (mine && !inMailbox) 'p': true,
        if (seen) 's': true,
        if (seenBy.isNotEmpty) 'sb': seenBy,
        if (edited) 'ed': true,
        if (reactions.isNotEmpty) 'r': reactions,
        if (burnAt != null) 'b': burnAt!.millisecondsSinceEpoch,
      };

  static StoredMessage fromJson(Map<String, dynamic> j) => StoredMessage(
        text: j['t'] as String? ?? '',
        mine: j['m'] as bool? ?? false,
        at: DateTime.fromMillisecondsSinceEpoch(j['a'] as int? ?? 0),
        author: j['w'] as String? ?? '',
        inMailbox: j['p'] != true,
        seen: j['s'] == true,
        seenBy: (j['sb'] as List? ?? const []).cast<String>(),
        edited: j['ed'] == true,
        reactions: (j['r'] as Map?)?.map((k, v) =>
                MapEntry('$k', (v as List).map((e) => '$e').toList())) ??
            const {},
        burnAt: j['b'] is int
            ? DateTime.fromMillisecondsSinceEpoch(j['b'] as int)
            : null,
      );
}

/// A conversation as it survives a restart.
class StoredConversation {
  StoredConversation({
    required this.id,
    required this.title,
    required this.session,
    required this.messages,
    required this.lastActivity,
    this.nickname = '',
    this.picture,
    this.pinned = false,
    this.muted = false,
    this.receipts = false,
    this.unread = false,
    this.lastOpened,
    List<String>? burnAcks,
  }) : burnAcks = burnAcks ?? [];

  /// What this device calls them, overriding the label they chose.
  ///
  /// This is the closest thing here to a contact record, and it is the honest
  /// shape of one: a name is a note you keep about somebody, not a fact a
  /// directory told you. Nothing verifies a label, and the safety number is
  /// what verifies a person.
  String nickname;

  /// Their picture, as they sent it. Null until they do.
  ///
  /// Sent over the conversation rather than fetched, because there is nowhere
  /// to fetch it from. It lives here and nowhere else.
  Uint8List? picture;

  /// Kept at the top of the list.
  bool pinned;

  /// No sound, no vibration, no notification.
  bool muted;

  /// Whether this device tells them when their messages have been read.
  ///
  /// Off by default and per conversation, because a receipt is an extra
  /// envelope per read and therefore something an operator can count. See
  /// `signal.dart`.
  bool receipts;

  /// Marked unread by hand, or never opened since something arrived.
  bool unread;

  /// Expiring messages read here whose acknowledgement has not gone out yet.
  ///
  /// It is kept rather than sent and forgotten because reading happens
  /// offline. Somebody opens the conversation on a train, the message starts
  /// counting down on this device, and the deposit that would tell the sender
  /// so cannot be made. Losing it there would leave their copy waiting
  /// forever for a read that already happened, which is the one failure this
  /// whole mechanism exists to avoid. So the identifier waits here and goes
  /// out on the next join. See `signal.dart`.
  final List<String> burnAcks;

  /// When this conversation was last opened.
  ///
  /// The unread count is derived from this rather than stored as a number.
  /// A counter has to be incremented on arrival and cleared on read, and every
  /// path that forgets one of those leaves a badge that is wrong forever. A
  /// timestamp cannot drift: the count is however many of their messages came
  /// after it, computed when it is asked for.
  DateTime? lastOpened;

  /// How many of their messages have arrived since this was last opened.
  ///
  /// Only theirs. Our own are not news.
  int get unreadCount {
    final since = lastOpened;
    if (since == null) return messages.where((m) => !m.mine).length;
    return messages.where((m) => !m.mine && m.at.isAfter(since)).length;
  }

  /// Whether to show anything at all in the list.
  bool get hasUnread => unread || unreadCount > 0;

  /// What to show: the note this device keeps, or the label they chose.
  String get displayTitle => nickname.isNotEmpty ? nickname : title;

  final String id;

  /// What the user calls this conversation. Their label, not a claimed identity.
  String title;

  /// The sealed MLS session, or null when history is off.
  String? session;

  final List<StoredMessage> messages;
  DateTime lastActivity;

  StoredMessage? get lastMessage => messages.isEmpty ? null : messages.last;
}

/// Where everything lives.
///
/// Keys are namespaced so a future format can migrate rather than collide, and
/// nothing is written until [unlock] has produced a key.
class RotelyxStore {
  RotelyxStore._();
  static final instance = RotelyxStore._();

  static const _kProbe = 'rotelyx.probe';
  static const _kPreviews = 'rotelyx.previews';
  static const _kConnected = 'rotelyx.connected';
  static const _kWakeSecret = 'rotelyx.wake-secret';
  static const _kTransport = 'rotelyx.transport-identity';
  static const _kBiometric = 'rotelyx.biometric';
  static const _kIndex = 'rotelyx.index';
  static String _kSession(String id) => 'rotelyx.session.$id';
  static String _kLog(String id) => 'rotelyx.log.$id';

  /// The blob that proves a conversation PIN. Absent when it is not locked.
  static String _kChatLock(String id) => 'rotelyx.chat-lock.$id';

  final _box = GetStorage();
  WasmKey? _key;

  /// Conversations held for this run only, when history is off.
  ///
  /// Without a passphrase there is no key, so nothing can be written down. That
  /// is the intended behaviour and it is what the unlock screen promises: the
  /// application works and forgets when you close it.
  ///
  /// It was forgetting immediately instead. `save` returned at the first line
  /// when locked, `loadAll` read only from disk, and so a pairing that had
  /// just succeeded produced an empty conversation list. Found on a phone,
  /// after pairing it with a browser, which is the only way it could have been
  /// found: every automated test either unlocks first or never opens the list.
  ///
  /// This is what "forgets when you close it" actually means.
  final _ephemeral = <String, StoredConversation>{};

  /// True once a passphrase has been accepted this run.
  bool get isUnlocked => _key != null;

  /// Whether a locked screen may show what a message said.
  ///
  /// Kept outside the encrypted log on purpose. It has to be readable before
  /// the vault is unlocked, because a message can arrive while the application
  /// is locked and the decision about what to put on the screen cannot wait
  /// for a passphrase. It says nothing about any conversation: it is one
  /// boolean about this device's own lock screen.
  bool get showPreviews => _box.read(_kPreviews) as bool? ?? true;

  set showPreviews(bool value) => _box.write(_kPreviews, value);

  /// Whether to hold the connection while the application is not in front.
  ///
  /// Off by default. It is a permanent notification and a battery cost, and an
  /// application that switches that on for you without asking has decided
  /// something about your phone that was not its decision to make.
  bool get stayConnected => _box.read(_kConnected) as bool? ?? false;

  set stayConnected(bool value) => _box.write(_kConnected, value);

  /// Read something that has to be legible before the vault is open.
  ///
  /// Deliberately narrow, and deliberately not a general key-value store. The
  /// three settings above and the PIN lock in `lock.dart` are the only things
  /// that need this, and they need it for the same reason: they are consulted
  /// on a screen shown *before* a passphrase has been given, so a value sealed
  /// under the vault key cannot be one of them.
  ///
  /// Anything that is about a conversation belongs in the sealed log instead.
  /// If a caller reaches for this to store a message, a name or a picture,
  /// that caller is wrong and this comment is why.
  Object? unsealed(String key) => _box.read(key);

  /// Write one. Null removes it.
  void writeUnsealed(String key, Object? value) {
    if (value == null) {
      _box.remove(key);
    } else {
      _box.write(key, value);
    }
  }

  /// Whether a fingerprint may stand in for the application PIN.
  ///
  /// Off by default, and outside the vault like the other settings, because it
  /// is consulted on the PIN screen itself. It holds no secret: it is one
  /// boolean saying whether to offer the prompt.
  bool get useBiometric => _box.read(_kBiometric) as bool? ?? false;

  set useBiometric(bool value) => _box.write(_kBiometric, value);

  /// This device's long-term name on the call transport.
  ///
  /// Thirty two bytes, made once and kept. Outside the vault for the same
  /// reason as the settings above: a call can arrive while the application is
  /// locked, and an identity that needs a passphrase is one that cannot answer.
  ///
  /// It is not a message key and opens nothing. What it is, is stable, which is
  /// the point: the same bytes on two devices is one identity in two places,
  /// and the transport will not stop that and nobody will enjoy debugging it.
  String get transportIdentity {
    final held = _box.read(_kTransport) as String?;
    if (held != null && held.length == 64) return held;

    final fresh = newSecret();
    _box.write(_kTransport, fresh);
    return fresh;
  }

  /// What proves to the mailbox that a revocation came from this device.
  ///
  /// Made once and kept. Outside the vault, like the two settings above, and
  /// for the same reason: notifications are switched on and off while the
  /// application is locked, and a secret that cannot be read without a
  /// passphrase is one that cannot revoke.
  ///
  /// It is not sensitive in the way the vault key is. The worst somebody can
  /// do with it is stop this device being woken, which is what its owner would
  /// be doing with it anyway.
  String get wakeSecret {
    final held = _box.read(_kWakeSecret) as String?;
    if (held != null && held.isNotEmpty) return held;

    final fresh = newSecret();
    _box.write(_kWakeSecret, fresh);
    return fresh;
  }

  /// True when something was stored on a previous run.
  bool get hasVault => _box.read(_kProbe) != null;

  // ---------------------------------------------------------------------------
  // Locking
  // ---------------------------------------------------------------------------

  /// Create a vault. Costs about a second: that is Argon2id doing its job.
  ///
  /// Replacing an existing key releases it first, for the reason [unlock]
  /// explains.
  ///
  /// Throws with the wasm's own message when the passphrase is too short, it
  /// explains what the passphrase protects, which is better than a length rule.
  Future<void> create(String passphrase) async {
    _key?.dispose();
    final key = RotelyxWasm.newKey(passphrase);
    // A sealed constant proves later that a passphrase is right without keeping
    // anything that could verify it offline more cheaply than the real data.
    _box.write(_kProbe, RotelyxWasm.sealBlob(key, base64Encode(utf8.encode('rotelyx'))));
    _key = key;
  }

  /// Open an existing vault. Returns false when the passphrase is wrong.
  ///
  /// A wrong passphrase still derives a key, because the derivation cannot know
  /// it is wrong; it is opening the probe that fails. So the key is released on
  /// the way out of a failed attempt. In a browser the collector would take
  /// care of it, but the native engine holds each one in a registry until it is
  /// told otherwise, and somebody mistyping a passphrase ten times should not
  /// leave ten of them behind.
  Future<bool> unlock(String passphrase) async {
    final probe = _box.read(_kProbe) as String?;
    if (probe == null) return false;

    WasmKey? key;
    try {
      key = RotelyxWasm.unlockKey(passphrase, probe);
      // Opening the probe is the check: a wrong key fails the AEAD tag.
      RotelyxWasm.openBlob(key, probe);
      _key = key;
      return true;
    } on Object {
      key?.dispose();
      return false;
    }
  }

  /// Forget the key. The blobs stay on disk; nothing can read them until the
  /// passphrase is given again.
  void lock() {
    // Every conversation PIN as well. Leaving one open would mean a locked
    // conversation readable after the vault itself was shut.
    chat_lock.closeAll();
    _key?.dispose();
    _key = null;
    _ephemeral.clear();
  }

  /// Delete everything, for a user who wants the record gone.
  void wipe() {
    for (final id in conversationIds) {
      _box.remove(_kSession(id));
      _box.remove(_kLog(id));
      _box.remove(_kChatLock(id));
    }
    _box.remove(_kIndex);
    _box.remove(_kProbe);
    _ephemeral.clear();
    _key?.dispose();
    _key = null;
  }

  // ---------------------------------------------------------------------------
  // Conversations
  // ---------------------------------------------------------------------------

  List<String> get conversationIds => _key == null
      ? _ephemeral.keys.toList()
      : (_box.read(_kIndex) as List?)?.cast<String>() ?? const [];

  void _index(String id, {required bool add}) {
    final ids = conversationIds.toList();
    if (add) {
      if (!ids.contains(id)) ids.add(id);
    } else {
      ids.remove(id);
    }
    _box.write(_kIndex, ids);
  }

  /// Persist a conversation. Silently does nothing while locked, so callers can
  /// save unconditionally and history simply does not accumulate when it is off.
  void save(StoredConversation c) {
    final key = _key;
    if (key == null) {
      _ephemeral[c.id] = c;
      return;
    }

    final payload = jsonEncode({
      'title': c.title,
      'at': c.lastActivity.millisecondsSinceEpoch,
      'messages': c.messages.map((m) => m.toJson()).toList(),
      if (c.nickname.isNotEmpty) 'nick': c.nickname,
      if (c.picture != null) 'pic': base64Encode(c.picture!),
      if (c.pinned) 'pin': true,
      if (c.muted) 'mute': true,
      if (c.receipts) 'rcpt': true,
      if (c.unread) 'unread': true,
      if (c.lastOpened != null)
        'opened': c.lastOpened!.millisecondsSinceEpoch,
      if (c.burnAcks.isNotEmpty) 'acks': c.burnAcks,
    });

    // A locked conversation is sealed twice: once under its own PIN and then
    // under the vault key like everything else. Both are needed to read it,
    // which is what makes it a lock rather than a hidden screen. See
    // `chat_lock.dart`.
    var inner = base64Encode(utf8.encode(payload));

    if (isLocked(c.id)) {
      final chatKey = chat_lock.keyFor(c.id);
      if (chatKey == null) {
        // Locked and not opened this run. Refusing to write is right: saving
        // it under the vault key alone would quietly remove the lock, and a
        // lock that comes off when something forgot to ask is not one.
        return;
      }
      inner = RotelyxWasm.sealBlob(chatKey, inner);
    }

    _box.write(_kLog(c.id), RotelyxWasm.sealBlob(key, inner));

    final session = c.session;
    if (session != null) _box.write(_kSession(c.id), session);

    _index(c.id, add: true);
  }

  /// Every stored value, for a test that asserts a secret is not among them.
  ///
  /// Only ever called from `test/chat_lock_test.dart`. It exists because
  /// "the PIN is not stored" is a claim worth checking against the storage
  /// rather than against the code that was supposed to not store it.
  List<Object?> debugAllValues() =>
      _box.getKeys<Iterable<String>>().map(_box.read<Object?>).toList();

  /// Whether this conversation has a PIN of its own.
  bool isLocked(String id) => _box.read(_kChatLock(id)) is String;

  /// Whether it has been opened during this run.
  bool isOpened(String id) => !isLocked(id) || chat_lock.isOpen(id);

  /// Give a conversation a PIN.
  ///
  /// Re-saves it immediately, so the sealed form on disk matches the lock from
  /// this moment rather than from the next time anything writes.
  void lockChat(String id, String pin) {
    final conversation = load(id);
    if (conversation == null) return;

    _box.write(_kChatLock(id), chat_lock.seal(id, pin));
    save(conversation);
  }

  /// Try a PIN.
  bool openChat(String id, String pin) {
    final probe = _box.read(_kChatLock(id));
    if (probe is! String) return true;
    return chat_lock.open(id, pin, probe);
  }

  /// Take the PIN off, which needs it to be open.
  void unlockChat(String id) {
    if (!isOpened(id)) return;

    final conversation = load(id);
    _box.remove(_kChatLock(id));
    chat_lock.close(id);
    if (conversation != null) save(conversation);
  }

  /// Read one back. Null when absent, locked, or sealed under another key.
  StoredConversation? load(String id) {
    final key = _key;
    if (key == null) return _ephemeral[id];

    final blob = _box.read(_kLog(id)) as String?;
    if (blob == null) return null;

    try {
      var inner = RotelyxWasm.openBlob(key, blob);

      if (isLocked(id)) {
        final chatKey = chat_lock.keyFor(id);
        // Null means the PIN has not been given this run. Null is returned
        // rather than a partial conversation, so nothing upstream can show a
        // preview of something that is supposed to be shut.
        if (chatKey == null) return null;
        inner = RotelyxWasm.openBlob(chatKey, inner);
      }

      final json = jsonDecode(utf8.decode(base64Decode(inner)))
          as Map<String, dynamic>;

      final picture = json['pic'];

      return StoredConversation(
        id: id,
        title: json['title'] as String? ?? 'Conversation',
        session: _box.read(_kSession(id)) as String?,
        messages: (json['messages'] as List? ?? [])
            .map((m) => StoredMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
        lastActivity:
            DateTime.fromMillisecondsSinceEpoch(json['at'] as int? ?? 0),
        nickname: json['nick'] as String? ?? '',
        picture: picture is String ? base64Decode(picture) : null,
        pinned: json['pin'] == true,
        muted: json['mute'] == true,
        receipts: json['rcpt'] == true,
        unread: json['unread'] == true,
        lastOpened: json['opened'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['opened'] as int)
            : null,
        burnAcks: (json['acks'] as List? ?? []).cast<String>(),
      );
    } on Object {
      // A blob that will not open is a blob from another passphrase or a
      // corrupted profile. Neither is worth crashing the list for.
      return null;
    }
  }

  /// Every conversation, newest first.
  List<StoredConversation> loadAll() {
    final out = <StoredConversation>[];
    for (final id in conversationIds) {
      final c = load(id);
      if (c != null) out.add(c);
    }
    // Pinned first, then newest. A pin is a statement about importance and
    // outranks recency, which is the whole reason somebody sets one.
    out.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.lastActivity.compareTo(a.lastActivity);
    });
    return out;
  }

  void remove(String id) {
    _ephemeral.remove(id);
    _box.remove(_kSession(id));
    _box.remove(_kLog(id));
    _index(id, add: false);
  }

  /// Seal the live MLS state for [id].
  ///
  /// Call after every send and every receive. The ratchet advances on both, and
  /// a session restored from a blob that is one message behind cannot decrypt
  /// what arrives next.
  void saveSession(String id, WasmSession session) {
    final key = _key;
    // Nothing to seal it with, and nothing lost: an unsealed session is one
    // that was never going to survive a restart anyway.
    if (key == null) return;
    try {
      _box.write(_kSession(id), session.sealSession(key));
      _index(id, add: true);
    } on Object {
      // Failing to persist must never break a live conversation.
    }
  }

  String? sessionBlob(String id) => _box.read(_kSession(id)) as String?;

  WasmKey? get key => _key;
}

final store = RotelyxStore.instance;
