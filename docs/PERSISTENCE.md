# Persistence

**Status: not implemented, and not implementable in this repository.**

Reloading the page ends the conversation. That is the largest gap between this
client and a usable chat application, and it cannot be closed here: the MLS group
state lives in wasm memory and `rotelyx-wasm` exposes no way to get it out.

This note records what the protocol repository would need to add, and, more
importantly, what storing that state safely actually costs.

## Why the app cannot work around it

`rotelyx-wasm` exports `to_bytes` / `from_bytes` for individual primitives:
hybrid public keys, ciphertexts, envelopes, key packages. None of them is the
group. `Session` holds a `Conversation`, which holds an `MlsGroup`, and neither
is reachable from JavaScript.

Nothing the Dart layer can do reconstructs an MLS group from the outside. Storing
the meeting phrase and re-pairing on reload is not the same thing, it is a new
group, a new epoch, a new safety number, and the other party has to be present.

## What the protocol repository would add

The pieces are already in place, which is why this is worth writing down rather
than filing as a wish.

`rotelyx-crypto` uses `openmls_memory_storage::MemoryStorage` (0.5.0), and that
type already round-trips:

```rust
pub fn serialize(&self, w: &mut Vec<u8>) -> std::io::Result<usize>
pub fn deserialize<R: std::io::Read>(r: &mut R) -> std::io::Result<Self>
```

So the shape is:

1. **`rotelyx-crypto`**: expose the provider's storage, plus the group id.
   OpenMLS 0.8 reloads a group from storage with `MlsGroup::load(storage, group_id)`.
2. **`rotelyx-wasm`**: add two calls to `Session`:
   ```rust
   #[wasm_bindgen(js_name = exportState)]
   pub fn export_state(&self) -> Result<String, Error>   // base64

   #[wasm_bindgen(js_name = restoreState)]
   pub fn restore_state(blob_b64: &str) -> Result<Session, Error>
   ```
   The blob must carry the serialized storage, the group id, and the member's
   signature key, since a restored group without its signer can read but not send.
3. **This client**: persist the blob in IndexedDB and offer to restore on load.

## The part that is not a storage problem

**The export is the entire conversation.** It contains the signature private key,
the MLS secret tree, and the tag key, everything needed to read every message
and to speak as that member.

Writing it to IndexedDB unencrypted would mean:

- any XSS on this origin reads the whole conversation history and impersonates
  the user, where today it gets one tab's memory and nothing after a reload
- the "closed tab leaves nothing behind" property in the wasm documentation stops
  being true, and it is currently one of the better properties this build has
- device seizure becomes a full compromise rather than a partial one

So persistence has to arrive **with** encryption at rest, not before it:

- derive a key from a user passphrase (Argon2id, not PBKDF2 with a low count) and
  seal the blob under it, or
- wrap it with a non-extractable WebCrypto key held in IndexedDB, which stops an
  attacker who exfiltrates storage but not one running script on the origin, so it
  is weaker than it looks and should be described as such

Either way the threat model changes and `docs/THREAT-MODEL.md` has to change with
it. A build that silently gains at-rest secrets is a build whose documentation is
now wrong.

## Recommended order

1. `exportState` / `restoreState` in the protocol repository, with test vectors
2. Passphrase-derived encryption at rest, specified before it is implemented
3. The threat model updated to say what an attacker with the device now gets
4. Only then the IndexedDB layer in this client, which is the easy part

Until step 1 exists, this client is correct to hold everything in memory and say
so on screen.
