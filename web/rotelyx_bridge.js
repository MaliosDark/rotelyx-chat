// Rotelyx bridge, by Ideoa Labs
//
// Dart's js_interop cannot construct a JS BigInt, and several rotelyx-wasm
// entry points take u64 time buckets. This file is the one place BigInt exists:
// it exposes the same API in plain numbers so Dart never sees one.
//
// It also owns the ES module import, which Dart cannot do directly.
//
// No protocol logic lives here. The handshake is in lib/rotelyx/, once, so the
// two cannot drift.

import init, {
  Session, SessionKey, start,
  rendezvousTag, sealUnder, openUnder, sealBlob, openBlob,
  protocolVersion, maxMembers,
} from './rotelyx/rotelyx_wasm.js';

/// Hours since the Unix epoch. Mailbox tags rotate on this; both sides must
/// agree, which is why it is coarse enough that clock skew does not matter.
const bucket = () => Math.floor(Date.now() / 3_600_000);

/// Wraps one wasm Session so every u64 crossing the boundary converts here.
class Handle {
  constructor(session) { this.s = session; }

  static create(label) { return new Handle(new Session(label)); }

  /// Rebuild from a sealed blob. Throws on a wrong passphrase, which the caller
  /// shows as "wrong passphrase" rather than as a crash.
  static unseal(blob, key) { return new Handle(Session.unsealSession(blob, key)); }

  // ---- identity ------------------------------------------------------------
  keyPackage()      { return this.s.keyPackage(); }
  hybridPublicKey() { return this.s.hybridPublicKey(); }
  safetyNumber()    { return this.s.safetyNumber(); }
  roster()          { return this.s.roster(); }

  get epoch()       { return Number(this.s.epoch); }
  get memberCount() { return Number(this.s.memberCount); }

  // ---- membership ----------------------------------------------------------
  found()            { this.s.found(); }
  join(w, t)         { this.s.join(w, t); }
  encapsulateTo(pk)  { return this.s.encapsulateTo(pk); }
  openPq(ct)         { this.s.openPq(ct); }
  commitPq()         { return this.s.commitPq(); }
  beginGroupPq(pks)  { return this.s.beginGroupPq(pks); }
  openGroupPq(w)     { this.s.openGroupPq(w); }

  invite(keyPackageB64) {
    const i = this.s.invite(keyPackageB64);
    return { commit: i.commit, welcome: i.welcome, ratchetTree: i.ratchetTree };
  }

  // ---- messages ------------------------------------------------------------
  send(text) { return this.s.send(text); }

  /// Plaintext, or null for a commit, which is not an error: the group changed.
  receive(messageB64) {
    const out = this.s.receive(messageB64);
    return out === undefined ? null : out;
  }

  // ---- addressing ----------------------------------------------------------
  //
  // Per member, not per group: mailbox collection removes, so a shared tag
  // would deliver each message to exactly one person.
  myTag()               { return this.s.myTag(BigInt(bucket())); }
  myPollingTags(look)   { return this.s.myPollingTags(BigInt(bucket()), BigInt(look)); }
  recipientTags()       { return this.s.recipientTags(BigInt(bucket())); }
  commitRecipientTags() { return this.s.commitRecipientTags(BigInt(bucket())); }

  sealForGroup(ct)       { return this.s.sealForGroup(ct, BigInt(bucket())); }
  sealCommitForGroup(c)  { return this.s.sealCommitForGroup(c, BigInt(bucket())); }
  openMine(env, look)    { return this.s.openMine(env, BigInt(bucket()), BigInt(look)); }

  // ---- persistence ---------------------------------------------------------
  //
  // The ratchet turns on every send and every receive, so this must be called
  // after both or a restored session is behind and cannot decrypt.
  sealSession(key) { return this.s.sealSession(key); }
}

async function boot() {
  await init();
  start();

  window.rotelyx = {
    ready: true,
    version: protocolVersion(),
    maxMembers: maxMembers(),
    bucket,

    newSession: (label) => Handle.create(label),
    unsealSession: (blob, key) => Handle.unseal(blob, key),

    // Argon2id at 64 MiB: about a second, once, at unlock. The key is held for
    // the tab and zeroized on drop.
    newKey: (passphrase) => SessionKey.create(passphrase),
    unlockKey: (passphrase, blob) => SessionKey.unlock(passphrase, blob),

    rendezvousTag, sealUnder, openUnder,

    // Arbitrary bytes under the same key. Used for the message log, which is
    // the one place this app writes readable text at rest.
    sealBlob, openBlob,
  };

  window.dispatchEvent(new Event('rotelyx-ready'));
}

boot().catch((e) => {
  console.error('rotelyx: wasm failed to load', e);
  window.rotelyx = { ready: false, error: String(e) };
  window.dispatchEvent(new Event('rotelyx-ready'));
});
