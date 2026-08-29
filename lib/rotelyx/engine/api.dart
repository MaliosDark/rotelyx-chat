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

  RotelyxInvitation invite(String keyPackageB64);
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
  List<String> beginGroupPq(List<String> hybridPublicKeys);
  void openGroupPq(String wrappedB64);

  String send(String text);

  /// Plaintext, or null for a commit, which is not an error: the group changed.
  String? receive(String messageB64);

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

  String sealUnder(String tagHex, String payloadB64);
  String openUnder(String envelopeB64, String tagHex);

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
