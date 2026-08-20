/// Locking the application, and locking one conversation.
///
/// # The distinction that has to be built in rather than discovered
///
/// These are two different things and only one of them is a lock.
///
/// **The application PIN is a curtain.** It decides whether the interface is
/// drawn. The conversation log is already sealed under the vault key, and the
/// PIN does not change that: somebody who takes the phone and reads the storage
/// directly gets the same ciphertext with or without it. What it stops is
/// somebody picking up an unlocked phone and reading over your shoulder, which
/// is the threat people actually meet.
///
/// **A conversation PIN has to be a lock.** If it only decided whether a screen
/// was drawn, then the conversation would still be readable to anything that
/// could open the vault, which includes this application with the wrong screen
/// shown. So it derives a second key, and the conversation is sealed under
/// that. Getting it wrong here does not produce a weak lock, it produces a
/// curtain with a padlock drawn on it.
///
/// # Why the PIN is stretched and the passphrase is not stretched here
///
/// A four digit PIN has about thirteen bits in it. Ten thousand guesses is not
/// a search, it is a morning. So the check has to be expensive on purpose, and
/// the only thing standing between a stolen phone and the answer is how long
/// each attempt takes.
///
/// `RotelyxWasm.deriveKey` is Argon2, which is what the vault already uses for
/// the passphrase, and it is used here with the same parameters. That makes ten
/// thousand guesses expensive rather than instant, and it is the whole of the
/// defence: a PIN is short and nothing changes that.
///
/// It is therefore stated plainly in the interface. A PIN is a lock against a
/// person who picked up your phone, not against somebody who took it away with
/// a laboratory.
///
/// # Why failures are counted and the count survives a restart
///
/// Otherwise the attempt limit is defeated by force-quitting the application,
/// which is a thing anybody can do and which turns the limit into decoration.
library;

import 'rotelyx_store.dart';
import 'rotelyx_wasm.dart';

/// How many wrong PINs before this device stops answering for a while.
const int maxAttempts = 10;

/// How long it stops for, in seconds, once the attempts are used up.
///
/// Five minutes rather than forever. A person who mistypes their own PIN ten
/// times is far more common than an attacker, and an application that wipes
/// itself is one that a spilled pocket can destroy.
const int lockoutSeconds = 300;

/// The shortest PIN this accepts.
///
/// Four, because that is what people expect and refusing it would send them to
/// an application with no lock at all. Six is offered and encouraged, and the
/// difference between them is stated in the interface rather than implied by a
/// validation message.
const int minPinLength = 4;

/// Locking, on this device.
class Lock {
  const Lock();

  static const _kProbe = 'rotelyx.lock.probe';
  static const _kFailed = 'rotelyx.lock.failed';
  static const _kUntil = 'rotelyx.lock.until';

  /// Whether an application PIN has been set.
  bool get isSet => store.unsealed(_kProbe) is String;

  /// Set or change it. An empty PIN removes the lock.
  void setPin(String pin) {
    if (pin.isEmpty) {
      store.writeUnsealed(_kProbe, null);
      _clearFailures();
      return;
    }

    // The same shape the vault uses for a passphrase: a key derived from the
    // secret, and a blob sealed under it. Checking is opening the blob, and a
    // wrong key fails the AEAD tag rather than being compared to anything.
    //
    // Written this way rather than as a stored hash because it reuses the
    // derivation the vault has already been trusted with, salt and cost and
    // all, instead of inventing a second one beside it that looks similar.
    final key = RotelyxWasm.newKey(_input(pin));
    try {
      store.writeUnsealed(_kProbe, RotelyxWasm.sealBlob(key, ''));
    } finally {
      key.dispose();
    }
    _clearFailures();
  }

  /// Whether [pin] is the one that was set.
  ///
  /// Counts a failure when it is not, and refuses outright while locked out.
  /// Returns null in that case rather than false, so the interface can say why
  /// instead of claiming the PIN was wrong.
  bool? check(String pin) {
    if (lockedOutFor > 0) return null;

    final probe = store.unsealed(_kProbe);
    if (probe is! String) return true;

    WasmKey? key;
    try {
      key = RotelyxWasm.unlockKey(_input(pin), probe);
      RotelyxWasm.openBlob(key, probe);
      _clearFailures();
      return true;
    } on Object {
      key?.dispose();

      final failed = (store.unsealed(_kFailed) as int? ?? 0) + 1;
      store.writeUnsealed(_kFailed, failed);
      if (failed >= maxAttempts) {
        store.writeUnsealed(_kUntil,
            DateTime.now().millisecondsSinceEpoch + lockoutSeconds * 1000);
      }
      return false;
    } finally {
      key?.dispose();
    }
  }

  /// How many wrong attempts remain before this device stops answering.
  int get attemptsLeft => maxAttempts - (store.unsealed(_kFailed) as int? ?? 0);

  /// Seconds until this device will answer again, or zero.
  int get lockedOutFor {
    final until = store.unsealed(_kUntil);
    if (until is! int) return 0;

    final left = until - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) {
      // Expired. Cleared on being asked rather than on a timer, because a timer
      // only runs while the application is open and a restart would defeat it.
      _clearFailures();
      return 0;
    }
    return (left / 1000).ceil();
  }

  /// What is actually handed to the derivation.
  ///
  /// Two reasons, and the first is the one that made this necessary.
  ///
  /// **The engine refuses a passphrase under eight characters**, and it is
  /// right to: a passphrase protects a conversation, and a short one is a short
  /// walk to it. A PIN is a different thing with a different threat behind it,
  /// so it does not get to borrow that argument, and it does not get to bypass
  /// the check either. It arrives as part of a longer string.
  ///
  /// **Domain separation.** Without the prefix, somebody whose PIN happened to
  /// equal their passphrase would derive the same key for two unrelated things,
  /// and the app lock's probe would be a free test of the vault passphrase. The
  /// version in it is so that changing this scheme later cannot silently accept
  /// a PIN set under the old one.
  ///
  /// None of this makes a four digit secret longer. What protects it is the
  /// cost of each guess and the attempt limit above, both of which are stated
  /// plainly in the interface rather than implied.
  static String _input(String pin) => 'rotelyx.app-pin.v1:$pin';

  void _clearFailures() {
    store.writeUnsealed(_kFailed, null);
    store.writeUnsealed(_kUntil, null);
  }
}

/// The one this application uses.
const Lock lock = Lock();
