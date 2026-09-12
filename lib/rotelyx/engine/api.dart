/// What the message engine offers, stated without reference to any platform.
///
/// # Why this file exists
///
/// The engine is one Rust crate. In a browser it is WebAssembly reached through
/// `web/rotelyx_bridge.js`; on a phone it is a shared library reached through
/// `dart:ffi`. Same crate, same protocol, two entirely different ways of
/// calling it.
///
/// Before this existed, `rotelyx_wasm.dart` imported `dart:js_interop`
/// directly, `rotelyx_service.dart` imported that, and so the whole core of the
/// application was web-only. `flutter build apk` failed at the first import and
/// the `android/` directory was scaffolding Flutter had generated and nobody
/// had ever used.
///
/// The types here are ordinary Dart. No `JSArray`, no handles, no pointers:
/// those belong to the implementations, and letting either leak upward is how
/// a platform detail becomes an architecture.
///
/// # On keeping the two in step
///
/// There is one engine and two wrappers, which is a shape that can drift. It
/// cannot drift far, because both are thin: neither computes anything, both
/// forward. Any logic appearing in either is a defect, and the same defect the
/// protocol repository's `rotelyx-mobile` warns about from the other side.
library;

/// A key derived from a passphrase. Opaque on purpose: the material never
/// crosses into Dart, only a reference to it.
/// A message that arrived, and who MLS says wrote it.
///
/// # Why the author is carried rather than inferred
///
/// With two people there is only one other person a message can be from, so
/// every caller inferred it and nothing broke. In a group that inference is
/// wrong, and it was wrong in a way nothing reported: read receipts were all
/// attributed to the conversation's own name, so the second member's receipt
/// looked like a repeat of the first and a group of three never showed a read
/// tick at all.
///
/// MLS authenticates the sending leaf and has since the beginning. The value
/// was dropped between the core and this interface.
class Received {
  const Received(
    this.text, {
    this.from,
    this.fromKey,
    this.proposedBy,
    this.joining = const <String>[],
    this.refused,
  });

  /// A request to admit somebody, which changes nothing until another member
  /// confirms it.
  ///
  /// This is the half of an addition that anybody can still do something
  /// about, which is why it comes back rather than being folded into "the
  /// group moved". By the time it is a membership change it is already done.
  const Received.proposal({required this.proposedBy, required this.joining})
      : text = '',
        from = null,
        fromKey = null,
        refused = null;

  /// The group declined to apply what arrived, and why.
  const Received.refused(String why)
      : text = '',
        from = null,
        fromKey = null,
        proposedBy = null,
        joining = const <String>[],
        refused = why;

  /// The plaintext. Empty when this was not a message.
  final String text;

  /// The member asking for an addition, when that is what arrived.
  ///
  /// Null for a request from outside the membership, which cannot be confirmed
  /// into anything and should be shown as unattributed.
  final String? proposedBy;

  /// Who that request would admit.
  final List<String> joining;

  /// Whether this was a request to admit somebody rather than something said.
  bool get isProposal => joining.isNotEmpty;

  /// Why the group refused to apply what arrived, when it did.
  ///
  /// A refusal is not a failure to decrypt and must never be reported as one.
  /// It means the sender moved to an epoch this device did not, so from here
  /// on their messages cannot be read: two ends at two points with nothing
  /// saying so is the exact failure this application spent a week chasing.
  final String? refused;

  /// The label the author joined under, when the group still holds their leaf.
  ///
  /// Null for a sender the group no longer has, and for a bridge older than
  /// this field. A caller must treat null as "unattributed" rather than as
  /// anybody in particular.
  final String? from;

  /// The key that identifies the author, when the group still holds their
  /// leaf.
  ///
  /// A label is what somebody joined under and two members can both claim
  /// one, so anything that acts on a particular member has to read this
  /// instead. It is the same value `rosterDetail` gives, which is what
  /// removal and blocking take.
  ///
  /// Null for a sender the group no longer has, and for an engine older than
  /// this field.
  final String? fromKey;
}

abstract interface class RotelyxKey {
  /// Release it. A browser leaves this to the garbage collector; a shared
  /// library does not have one, so the contract is explicit and both honour it.
  void dispose();
}

/// What [RotelyxSession.invite] produces.
class RotelyxInvitation {
  const RotelyxInvitation({
    required this.commit,
    required this.welcome,
    required this.ratchetTree,
  });

  final String commit;
  final String welcome;
  final String ratchetTree;
}

/// One member's view of one conversation.
///
/// Every method here forwards to the engine.
///
/// # The time bucket, which is not in these signatures
///
/// Tags rotate hourly, so the engine's addressing calls take the current hour
/// since the Unix epoch. It is absent here on purpose. The browser bridge
/// computes it inside `web/rotelyx_bridge.js`, a file copied verbatim from the
/// protocol repository and not ours to change; the native wrapper computes it
/// in `native.dart`. Both use `now / 3_600_000`, and a caller passing one would
/// be passing a value one of the two implementations must then ignore.
///
/// The rule is therefore duplicated, in exactly two places, both named here. If
/// it ever changes it changes in the protocol repository first, and both follow.
abstract interface class RotelyxSession {
  String keyPackage();
  String hybridPublicKey();

  String safetyNumber();
  List<String> roster();

  /// Everyone here, each with the key that identifies them.
  ///
  /// JSON: `[{"label":…,"key":…}]`, the key base64. [roster] gives the labels
  /// alone, which is right for showing who is present and useless for acting
  /// on one of them: a label is a claim, and two members can make the same one.
  String rosterDetail();

  /// Put a member out of the conversation, returning the commit to deliver.
  ///
  /// A removal is a commit and not a local setting. A device that is gone is a
  /// leaf that can still decrypt, and forgetting it here changes nothing: the
  /// key schedule includes it until the group says otherwise. Everybody who
  /// applies the commit moves to an epoch derived without that leaf, which is
  /// also what makes the removal visible rather than something the removed
  /// device could ignore.
  ///
  /// It does not reach backwards. What that member could already read, it
  /// keeps.
  ///
  /// Deliver the result with [sealCommitForGroup], addressed at the epoch the
  /// others are still on, exactly as an invitation's commit is.
  String removeMember(String signatureKeyB64);
  int get epoch;
  int get memberCount;

  /// Start a group with this member as its only occupant.
  void found();

  /// Admit somebody on this member's own authority.
  ///
  /// Only two cases produce a commit the rest of the group will accept: a
  /// conversation with one member, which is first contact, and a leaf
  /// belonging to the same person as this one, which is somebody's own second
  /// device. Anywhere else, admitting takes two members: [propose] and then
  /// somebody else's [confirmAdditions].
  RotelyxInvitation invite(String keyPackageB64);

  /// Apply this member's own commit, once every copy of it is in the mailbox.
  ///
  /// Until this is called the device is still standing where the other members
  /// are, which is what lets it take a commit somebody else made at the same
  /// moment instead of its own. Two devices reopening at once is exactly how
  /// two ends used to end up at two epochs neither could leave.
  ///
  /// Never before the deposit: sealing addresses the epoch the others are
  /// still on, and that is what moves them off it.
  ///
  /// Returns whether there was anything to settle.
  bool settle();

  /// Whether this device is holding a commit it has not applied.
  bool isHoldingACommit();

  /// The members this group allows to turn a request into a member, by the
  /// labels the roster uses. Empty when it allows everybody.
  List<String> admins();

  /// Name those members. An empty list turns the rule off.
  ///
  /// Returns the commit to broadcast. It narrows who may let somebody in, not
  /// who may ask: an ordinary member proposing somebody is what a request to
  /// join looks like from inside the group.
  String setAdmins(List<String> labels);

  /// The datagram that seats this member in a call's room, base64.
  ///
  /// Sent first on the room connection and nothing else. Names the room,
  /// derived from the call so every member lands in the same one, and the
  /// seat, this member's sender index so its frames are routed as its own.
  String roomJoin(String callId);

  /// Ask the group to admit somebody. Nothing changes until another member
  /// confirms it.
  ///
  /// The proposal goes to every member, not only to whoever is expected to
  /// confirm: a commit that refers to a proposal cannot be processed by
  /// anybody who never saw it.
  String propose(String keyPackageB64);

  /// Turn the additions somebody else proposed into a commit.
  ///
  /// Refused by the rest of the group if this member is the one that proposed
  /// them.
  RotelyxInvitation confirmAdditions();

  void join(String welcomeB64, String ratchetTreeB64);

  String encapsulateTo(String hybridPublicKeyB64);
  void openPq(String ciphertextB64);
  String commitPq();

  /// Move a conversation read back from storage to a fresh epoch.
  ///
  /// A file is a copy, and a copy that resumes sending is sending at
  /// generations the other side has already spent: a receiver deletes each
  /// generation's secret as it uses it, so those messages are refused and
  /// nothing reports it. The engine marks a restored session and refuses to
  /// send until this has run.
  ///
  /// Returns the commit, which has to be delivered before anything else.
  String rekeyAfterRestore();

  /// Say this reopened session is the newest, so it may send as it is.
  ///
  /// The alternative is [rekeyAfterRestore], which works and moves the epoch.
  /// Two devices that move it without seeing each other end up at two epochs
  /// neither can leave, and that is not a dropped message: it is two
  /// conversations where there was one. Only a caller that seals after
  /// everything that moves the state may say this.
  void trustRestoredState();
  List<String> beginGroupPq(List<String> hybridPublicKeys);
  void openGroupPq(String wrappedB64);

  String send(String text);

  /// What arrived, or null for a commit, which is not an error: the group
  /// changed.
  Received? receive(String messageB64);

  String myTag();
  List<String> myPollingTags(int lookback);
  List<String> recipientTags();
  List<String> commitRecipientTags();

  List<String> sealForGroup(String ciphertextB64);
  List<String> sealCommitForGroup(String ciphertextB64);
  String openMine(String envelopeB64, int lookback);

  String sealSession(RotelyxKey key);

  /// Release it. See [RotelyxKey.dispose].
  void dispose();
}

/// The engine itself.
abstract interface class RotelyxEngine {
  /// Whether it is loaded and usable.
  bool get ready;

  /// Why it is not, when it is not.
  String? get error;

  String? get version;
  int get maxMembers;

  /// Completes when the engine is up, or throws [RotelyxUnavailable].
  ///
  /// On the web the module is a couple of megabytes and the first frame paints
  /// well before it can be used. On a phone the library is already resident, so
  /// this returns immediately, and it still exists there so that callers do not
  /// have to know which they are on.
  Future<void> whenReady({Duration timeout});

  RotelyxSession newSession(String label);

  /// A session that is one **device** of a person, rather than the person.
  ///
  /// Its own leaf, its own signing key, its own row in the roster, and
  /// removable on its own while the person stays. The alternative, devices
  /// sharing one key, cannot be taken from one device without being taken from
  /// all of them, and leaves nothing able to say which device sent a message.
  ///
  /// An empty [device] is what [newSession] passes, and means the only one this
  /// person has.
  RotelyxSession newDeviceSession(String person, String device);

  /// The digits two devices of one person compare before one adds the other.
  ///
  /// Taken over the key package **as it arrived**, never over the copy of what
  /// was sent: that is the whole mechanism, and it is what lets the package
  /// travel by any route. Adding a device is an addition to every conversation
  /// its person is in, so a substituted package is the worst outcome available
  /// here, and two screens that stop agreeing is what catches one.
  ///
  /// See `docs/DEVICES.md` for the routes, and for the one rule none of them
  /// may break: a person has to see this.
  String deviceConfirmation(String keyPackageB64);

  RotelyxSession unsealSession(String blob, RotelyxKey key);

  RotelyxKey newKey(String passphrase);
  RotelyxKey unlockKey(String passphrase, String blob);

  /// Derive a meeting tag from a string both sides know.
  ///
  /// Not a secret channel and not authentication: whoever arrives first
  /// answers. Only the safety number detects that.
  String rendezvousTag(String phrase);

  /// What to name an envelope by when telling the mailbox it arrived.
  ///
  /// Delivery peeks and removal waits for this receipt, so an envelope nobody
  /// acknowledges sits until its seven-day TTL and the tag fills at 256, after
  /// which the server refuses deposits and messages are lost with nothing said
  /// to the sender. It is not optional housekeeping.
  ///
  /// The engine computes it because the digest is over the envelope's stored
  /// bytes, and computing it here would be a third implementation of the wire
  /// format.
  String receiptFor(String envelopeB64);

  /// Which tag an envelope was deposited under.
  ///
  /// One socket carries every conversation somebody has, which is what makes
  /// a message arrive while they are looking at a different one. The delivery
  /// frame says only "here is an envelope", so this is how a client knows
  /// where it belongs.
  ///
  /// Nothing is decrypted. The tag is the first thirty two bytes and is not
  /// encrypted, because the mailbox files by it and could not carry anything
  /// otherwise. Read through the engine rather than in Dart so that the
  /// layout is known in one place.
  String tagOf(String envelopeB64);

  String sealUnder(String tagHex, String payloadB64);
  String openUnder(String envelopeB64, String tagHex);

  /// Seal this device's push token to the notifier.
  ///
  /// One per tag, and never the same string twice: what makes the mailbox
  /// unable to tell that two tickets belong to one device is that they share
  /// no bytes. Leaving the same ticket under several tags would put a repeated
  /// value in its table, which is the thing the hourly rotation exists to
  /// prevent.
  ///
  /// [notifierKeyB64] is pinned in the build. Asking a server which key to
  /// seal to would let that server name its own and read every ticket.
  String sealWakeTicket(String notifierKeyB64, String kind, String token, int hour);

  /// A vault key from bytes the device holds, rather than from a passphrase.
  ///
  /// Thirty two bytes, base64url. The engine has had this path since the
  /// beginning and no client could reach it, which is why the only way to have
  /// a vault was to make somebody type for it.
  RotelyxKey keyFromDeviceBytes(String keyB64);

  /// Open a vault that was made with [keyFromDeviceBytes].
  RotelyxKey unlockWithDeviceBytes(String keyB64, String blobB64);

  String sealBlob(RotelyxKey key, String dataB64);
  String openBlob(RotelyxKey key, String blobB64);
}

/// The engine is missing, still loading, or broken.
class RotelyxUnavailable implements Exception {
  const RotelyxUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The engine reported a failure. Distinct from [RotelyxUnavailable]: the
/// engine is there and working, and it refused this particular call.
class RotelyxEngineError implements Exception {
  const RotelyxEngineError(this.message);
  final String message;
  @override
  String toString() => message;
}
