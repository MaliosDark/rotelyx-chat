/// Locking one conversation, which is a different thing from locking the app.
///
/// # The distinction, and why getting it wrong is worse than not building it
///
/// The application PIN in `lock.dart` decides whether the interface is drawn.
/// That is honest and it is useful: it stops somebody who picked up an unlocked
/// phone. It does not stop anybody who can read the storage, and it says so.
///
/// A conversation lock that worked the same way would be a lie. Somebody puts a
/// padlock on one conversation, believes that conversation is protected, and it
/// is sitting in the same blob as every other one, opened by the same key, and
/// visible to anything that can open the vault. A padlock painted on a curtain.
///
/// So this one has to seal. A locked conversation's log is encrypted **twice**:
/// once under a key derived from its own PIN, and then again under the vault
/// key like everything else. Both are needed. Forgetting the PIN loses that
/// conversation and nothing else, and nothing here can recover it.
///
/// # Why nesting rather than one key from both secrets
///
/// Because the vault passphrase is not kept. The store holds a derived key and
/// the passphrase is gone the moment it has been used, which is the right shape
/// and is worth not undoing to make this convenient. Nesting gets the same
/// property, both secrets required, without keeping a second copy of anything.
///
/// # What is still visible while it is locked
///
/// That the conversation exists, who it is with, and when something last
/// arrived. Those live in the index and the title, not in the sealed log, and
/// hiding them would mean hiding the row itself, which turns a locked
/// conversation into one nobody can find on purpose.
///
/// It is written here rather than left for somebody to notice, because a lock
/// that hides less than a person assumes is the failure this file exists to
/// avoid at the other end.
library;

import 'rotelyx_wasm.dart';

/// Conversation PINs given during this run, by conversation id.
///
/// In memory only, and gone when the process is. A locked conversation asks
/// again after a restart, which is the whole point of it being locked.
final Map<String, WasmKey> _opened = {};

/// What the derivation is actually given.
///
/// Domain separated from the application PIN and from a vault passphrase, so
/// somebody whose conversation PIN happens to equal one of those does not
/// derive the same key for two unrelated things. The version is so that
/// changing this scheme later cannot silently accept an old one.
String _input(String pin) => 'rotelyx.chat-lock.v1:$pin';

/// Whether this conversation has been opened during this run.
bool isOpen(String conversationId) => _opened.containsKey(conversationId);

/// Try a PIN. True when it opens the conversation.
///
/// The check is opening the blob: a wrong key fails the AEAD tag rather than
/// being compared against anything.
bool open(String conversationId, String pin, String probe) {
  WasmKey? key;
  try {
    key = RotelyxWasm.unlockKey(_input(pin), probe);
    RotelyxWasm.openBlob(key, probe);
    _opened[conversationId] = key;
    return true;
  } on Object {
    key?.dispose();
    return false;
  }
}

/// Lock a conversation for the first time, returning the probe to store.
String seal(String conversationId, String pin) {
  final key = RotelyxWasm.newKey(_input(pin));
  final probe = RotelyxWasm.sealBlob(key, '');
  _opened[conversationId] = key;
  return probe;
}

/// The key for a conversation opened this run, or null.
WasmKey? keyFor(String conversationId) => _opened[conversationId];

/// Close one, so it asks again.
void close(String conversationId) {
  _opened.remove(conversationId)?.dispose();
}

/// Close every one, which is what locking the application does.
void closeAll() {
  for (final key in _opened.values) {
    key.dispose();
  }
  _opened.clear();
}
