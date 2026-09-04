/// Dart bindings for `rotelyx-wasm`.
///
/// Everything crosses into `web/rotelyx_bridge.js`, which owns the BigInt
/// conversions and the ES module import. No protocol logic lives here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../call_api.dart';
import 'api.dart';
import 'net_web.dart';

@JS('rotelyx')
external _Ns? get _ns;

extension type _Ns._(JSObject _) implements JSObject {
  external bool get ready;
  external String? get error;
  external String? get version;
  external int get maxMembers;

  external WasmSessionJs newSession(String label);
  external WasmSessionJs unsealSession(String blob, WasmKeyJs key);

  external WasmKeyJs newKey(String passphrase);
  external WasmKeyJs unlockKey(String passphrase, String blob);

  external String rendezvousTag(String phrase);
  external String receiptFor(String envelopeB64);
  external String sealUnder(String tagHex, String payloadB64);
  external String openUnder(String envelopeB64, String tagHex);

  external String sealBlob(WasmKeyJs key, String dataB64);
  external String openBlob(WasmKeyJs key, String blobB64);
}

/// A key derived from a passphrase, held for the life of the tab and zeroized
/// on drop.
///
/// Deriving costs about a second (Argon2id, 64 MiB). That is the point, and it
/// is why the key is held rather than re-derived: the MLS state changes on
/// every message, so re-deriving per save would stall a second per message.
extension type WasmKeyJs._(JSObject _) implements JSObject {}

/// One party's view of one conversation.
extension type WasmSessionJs._(JSObject _) implements JSObject {
  // ---- identity -------------------------------------------------------------
  external String keyPackage();
  external String hybridPublicKey();

  /// Read it aloud. Comparing it over the channel an attacker controls proves
  /// nothing.
  external String safetyNumber();

  external JSArray roster();
  external String rosterDetail();
  external String removeMember(String signatureKeyB64);
  external int get epoch;
  external int get memberCount;

  // ---- membership -----------------------------------------------------------
  external void found();
  external WasmInvitationJs invite(String keyPackageB64);
  external void join(String welcomeB64, String ratchetTreeB64);
  external String encapsulateTo(String hybridPkB64);

  /// Stage a secret encapsulated to us. Must precede the matching commit: MLS
  /// looks the pre-shared key up by id and refuses the commit outright if it is
  /// missing, rather than quietly continuing without the post-quantum layer.
  external void openPq(String ciphertextB64);
  external String commitPq();
  external String rekeyAfterRestore();

  external JSArray beginGroupPq(JSArray hybridPublicKeys);
  external void openGroupPq(String wrappedB64);

  // ---- messages -------------------------------------------------------------
  external String send(String text);

  /// Null for a commit, which means the group changed rather than that anything
  /// failed.
  external String? receive(String messageB64);

  // ---- addressing -----------------------------------------------------------
  external String myTag();
  external JSArray myPollingTags(int lookback);
  external JSArray recipientTags();
  external JSArray commitRecipientTags();

  /// One envelope per other member, each under that member's own tag. This is
  /// what a group costs: an operator watching a burst of deposits can count it.
  external JSArray sealForGroup(String ciphertextB64);

  /// A commit addressed to members who have not applied it and so are still an
  /// epoch behind.
  external JSArray sealCommitForGroup(String commitB64);

  /// **Throws** when the envelope is not ours in this window; the caller treats
  /// that as "not for me" rather than as a failure.
  external String openMine(String envelopeB64, int lookback);

  // ---- persistence ----------------------------------------------------------
  //
  /// Seal the whole session. The ratchet turns on every send *and* receive, so
  /// this runs after both, a blob saved a message late cannot decrypt what
  /// comes next.
  external String sealSession(WasmKeyJs key);
}

extension type WasmInvitationJs._(JSObject _) implements JSObject {
  external String get commit;
  external String get welcome;
  external String get ratchetTree;
}


// -----------------------------------------------------------------------------
// The wrapper, adapting the bindings above to `api.dart`
// -----------------------------------------------------------------------------
//
// Nothing below computes anything. Every method forwards, and the only real
// work is turning a `JSArray` into a `List<String>`, which is where the browser
// stops being visible to the rest of the application.

_Ns _require() {
  final ns = _ns;
  if (ns == null) {
    throw const RotelyxUnavailable('the Rotelyx module has not loaded');
  }
  if (!ns.ready) {
    throw RotelyxUnavailable(ns.error ?? 'the Rotelyx module failed to load');
  }
  return ns;
}

/// `JSArray` is not generic on this SDK, so `toDart` yields `List<JSAny?>` and
/// each element has to be narrowed by hand.
List<String> _strings(JSArray array) =>
    array.toDart.map((e) => (e! as JSString).toDart).toList();

class _WebKey implements RotelyxKey {
  _WebKey(this.inner);
  final WasmKeyJs inner;

  /// Nothing to do. The browser collects it, which is the one place where this
  /// contract costs nothing to honour.
  @override
  void dispose() {}
}

class _WebSession implements RotelyxSession {
  _WebSession(this.inner);
  final WasmSessionJs inner;

  @override
  String keyPackage() => inner.keyPackage();
  @override
  String hybridPublicKey() => inner.hybridPublicKey();
  @override
  String safetyNumber() => inner.safetyNumber();
  @override
  List<String> roster() => _strings(inner.roster());

  @override
  String rosterDetail() => inner.rosterDetail();

  @override
  String removeMember(String signatureKeyB64) =>
      inner.removeMember(signatureKeyB64);
  @override
  int get epoch => inner.epoch;
  @override
  int get memberCount => inner.memberCount;
  @override
  void found() => inner.found();

  @override
  RotelyxInvitation invite(String keyPackageB64) {
    final i = inner.invite(keyPackageB64);
    return RotelyxInvitation(
        commit: i.commit, welcome: i.welcome, ratchetTree: i.ratchetTree);
  }

  @override
  void join(String welcomeB64, String ratchetTreeB64) =>
      inner.join(welcomeB64, ratchetTreeB64);
  @override
  String encapsulateTo(String hybridPublicKeyB64) =>
      inner.encapsulateTo(hybridPublicKeyB64);
  @override
  void openPq(String ciphertextB64) => inner.openPq(ciphertextB64);
  @override
  String commitPq() => inner.commitPq();

  @override
  String rekeyAfterRestore() => inner.rekeyAfterRestore();
  @override
  List<String> beginGroupPq(List<String> hybridPublicKeys) => _strings(
      inner.beginGroupPq(hybridPublicKeys.map((k) => k.toJS).toList().toJS));
  @override
  void openGroupPq(String wrappedB64) => inner.openGroupPq(wrappedB64);
  @override
  String send(String text) => inner.send(text);
  @override
  Received? receive(String messageB64) {
    // The core answers with JSON saying which of three things arrived, not with
    // the plaintext. Passed straight through, a message reached the screen as
    // `{"kind":"message","text":"hola"}`, and a rekey reached it as
    // `{"kind":"nothing"}`. The native engine had the mirror image of this bug
    // and dropped everything instead; both come from the same change to the
    // core that neither binding followed.
    final answer = inner.receive(messageB64);
    if (answer == null) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(answer);
    } on FormatException {
      // An older bridge, which returned the plaintext itself and no author.
      return Received(answer);
    }
    if (decoded is! Map) return Received(answer);

    if (decoded['kind'] == 'message') {
      final text = decoded['text'];
      if (text is! String) return null;
      final from = decoded['from'];
      return Received(text, from: from is String && from.isNotEmpty ? from : null);
    }
    // Membership and nothing both mean the group moved rather than that
    // somebody said something, which is what null means to the caller.
    return null;
  }

  // The bridge supplies the time bucket for all of these. See `api.dart`.
  @override
  String myTag() => inner.myTag();
  @override
  List<String> myPollingTags(int lookback) => _strings(inner.myPollingTags(lookback));
  @override
  List<String> recipientTags() => _strings(inner.recipientTags());
  @override
  List<String> commitRecipientTags() => _strings(inner.commitRecipientTags());
  @override
  List<String> sealForGroup(String ciphertextB64) =>
      _strings(inner.sealForGroup(ciphertextB64));
  @override
  List<String> sealCommitForGroup(String ciphertextB64) =>
      _strings(inner.sealCommitForGroup(ciphertextB64));
  @override
  String openMine(String envelopeB64, int lookback) =>
      inner.openMine(envelopeB64, lookback);

  @override
  String sealSession(RotelyxKey key) =>
      inner.sealSession((key as _WebKey).inner);

  @override
  void dispose() {}
}

class _WebEngine implements RotelyxEngine {
  const _WebEngine();

  @override
  bool get ready => _ns?.ready ?? false;
  @override
  String? get error => _ns?.error;
  @override
  String? get version => _require().version ?? 'unknown';
  @override
  int get maxMembers => _require().maxMembers;

  /// The bundle is a couple of megabytes, so the first frame paints well before
  /// it is usable. Waiting beats refusing a tap for something that was early.
  @override
  Future<void> whenReady({Duration timeout = const Duration(seconds: 30)}) {
    final ns = _ns;
    if (ns != null) {
      return ns.ready
          ? Future<void>.value()
          : Future<void>.error(
              RotelyxUnavailable(ns.error ?? 'the Rotelyx module failed to load'));
    }

    final done = Completer<void>();
    late final JSFunction listener;

    void settle() {
      if (done.isCompleted) return;
      final ns = _ns;
      if (ns == null) {
        done.completeError(
            const RotelyxUnavailable('the bridge never announced itself'));
      } else if (ns.ready) {
        done.complete();
      } else {
        done.completeError(
            RotelyxUnavailable(ns.error ?? 'the Rotelyx module failed to load'));
      }
    }

    listener = ((web.Event _) => settle()).toJS;
    web.window.addEventListener('rotelyx-ready', listener);

    return done.future
        .timeout(timeout,
            onTimeout: () => throw const RotelyxUnavailable(
                'the Rotelyx module did not load; is web/rotelyx/ being served?'))
        .whenComplete(() => web.window.removeEventListener('rotelyx-ready', listener));
  }

  @override
  RotelyxSession newSession(String label) =>
      _WebSession(_require().newSession(label));

  @override
  RotelyxSession unsealSession(String blob, RotelyxKey key) =>
      _WebSession(_require().unsealSession(blob, (key as _WebKey).inner));

  @override
  RotelyxKey newKey(String passphrase) => _WebKey(_require().newKey(passphrase));

  @override
  RotelyxKey unlockKey(String passphrase, String blob) =>
      _WebKey(_require().unlockKey(passphrase, blob));

  @override
  String rendezvousTag(String phrase) => _require().rendezvousTag(phrase);
  @override
  String receiptFor(String envelopeB64) => _require().receiptFor(envelopeB64);
  @override
  String sealUnder(String tagHex, String payloadB64) =>
      _require().sealUnder(tagHex, payloadB64);
  @override
  String openUnder(String envelopeB64, String tagHex) =>
      _require().openUnder(envelopeB64, tagHex);
  @override
  String sealBlob(RotelyxKey key, String dataB64) =>
      _require().sealBlob((key as _WebKey).inner, dataB64);
  @override
  String openBlob(RotelyxKey key, String blobB64) =>
      _require().openBlob((key as _WebKey).inner, blobB64);
}

/// The engine for this platform.
RotelyxEngine createEngine() => const _WebEngine();

// ---------------------------------------------------------------------------
// Calls, which a browser does not have
// ---------------------------------------------------------------------------
//
// Both return null rather than throwing, and `calls.dart` treats null as "this
// build cannot call" rather than as a failure. A browser tab has no microphone
// this application is willing to hold, no place to keep a transport identity
// that survives being closed, and no way to be woken when it is not open.
//
// They exist so that `backend.dart` exports the same names on both platforms
// and nothing above has to ask which one it is compiled for.

/// A browser cannot open a QUIC endpoint.
///
/// Typed the same as the native one rather than as `Object?`, because the
/// caller assigns the result to a `RotelyxEndpoint?` and an untyped null does
/// not fit. The type it names is the refusing one from `net_web.dart`.
RotelyxEndpoint? openEndpoint(
        {required String identityHex, required String relay}) =>
    null;

/// A browser has no transport symbols, and never did.
bool get transportIsBuilt => false;

/// And has no codec to open a call on.
RotelyxCall? openNativeCall(Object session,
        {required String call, int bytesPerFrame = 60, bool recoverLoss = false}) =>
    null;
