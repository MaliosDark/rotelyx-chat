/// The message engine, whichever platform this is.
///
/// # What changed, and why the name did not
///
/// This file used to be `dart:js_interop` bindings, which made everything that
/// imported it web-only: the service, the store, and therefore the entire core
/// of the application. `flutter build apk` failed on the first import.
///
/// It is now a facade over `engine/api.dart`, with `engine/web.dart` and
/// `engine/native.dart` behind it. The names here are unchanged so that
/// `rotelyx_service.dart`, which is the tested part, did not have to move.
///
/// # The two implementations
///
///   **Web.** WebAssembly through `web/rotelyx_bridge.js`.
///   **Everything else.** A shared library through `dart:ffi`, built from
///   `rotelyx-mobile` in the protocol repository, which wraps the same crate.
///
/// One engine, two wrappers, and neither contains protocol logic. If either
/// ever does, that is the defect: two implementations of a handshake diverge,
/// and the divergence presents as an interoperability bug while being a
/// security one.
library;

import 'engine/api.dart';
import 'engine/backend.dart' as backend;

export 'engine/api.dart'
    show RotelyxEngineError, RotelyxInvitation, RotelyxUnavailable;

/// A session, under the name the rest of the application already used.
typedef WasmSession = RotelyxSession;

/// A key, likewise.
typedef WasmKey = RotelyxKey;

/// An invitation, likewise.
typedef WasmInvitation = RotelyxInvitation;

/// The engine, resolved once for this platform.
final RotelyxEngine engine = backend.createEngine();

/// Entry point to the engine.
///
/// Static, because there is exactly one engine per process and threading an
/// instance through every call site would buy nothing: the platform is not a
/// runtime choice.
class RotelyxWasm {
  const RotelyxWasm._();

  static bool get isReady => engine.ready;
  static String get protocolVersion => engine.version ?? 'unknown';
  static int get maxMembers => engine.maxMembers;

  /// Completes when the engine is up.
  ///
  /// On the web that is a download; on a phone the library is already resident
  /// and this returns immediately. Callers do not need to know which.
  static Future<void> whenReady({Duration timeout = const Duration(seconds: 30)}) =>
      engine.whenReady(timeout: timeout);

  // ---- sessions --------------------------------------------------------------

  /// A fresh identity. [label] is a claim shown to other members, authenticated
  /// by the group but chosen by its holder: it says who someone *says* they
  /// are. The safety number is what verifies.
  static WasmSession newSession(String label) => engine.newSession(label);

  static WasmSession unsealSession(String blob, WasmKey key) =>
      engine.unsealSession(blob, key);

  // ---- keys ------------------------------------------------------------------

  static WasmKey newKey(String passphrase) => engine.newKey(passphrase);

  static WasmKey unlockKey(String passphrase, String blob) =>
      engine.unlockKey(passphrase, blob);

  // ---- rendezvous ------------------------------------------------------------

  /// Derive a meeting tag from a string both sides know.
  ///
  /// Not a secret channel and not authentication: whoever arrives first
  /// answers. Only the safety number detects that.
  static String receiptFor(String envelopeB64) => engine.receiptFor(envelopeB64);
  static String rendezvousTag(String phrase) => engine.rendezvousTag(phrase);

  static String sealUnder(String tagHex, String payloadB64) =>
      engine.sealUnder(tagHex, payloadB64);

  static String openUnder(String envelopeB64, String tagHex) =>
      engine.openUnder(envelopeB64, tagHex);

  /// Seal this device's push token to the notifier, for one tag.
  ///
  /// Every call gives different bytes for the same token, which is what keeps
  /// the mailbox from recognising two of this device's tickets as one device.
  static String sealWakeTicket(
          String notifierKeyB64, String kind, String token, int hour) =>
      engine.sealWakeTicket(notifierKeyB64, kind, token, hour);

  // ---- blobs -----------------------------------------------------------------

  /// Seal arbitrary bytes under a passphrase-derived key.
  ///
  /// This is the one place the application writes readable message text at
  /// rest. Everywhere else plaintext exists only in memory, for the moment it
  /// is on screen. That is why history is opt in.
  static String sealBlob(WasmKey key, String dataB64) =>
      engine.sealBlob(key, dataB64);

  static String openBlob(WasmKey key, String blobB64) =>
      engine.openBlob(key, blobB64);
}
