// Runs inside the page. Mirrors lib/rotelyx/rotelyx_service.dart step for step,
// so a divergence between this and the Dart is a real finding rather than a
// difference between two test harnesses.
window.__rx = (() => {
  const S = {
    joined: false, safety: null, epoch: 0, inbox: [], log: [], err: null,
    role: null, meeting: null, session: null, socket: null, listening: [],
  };
  const LOOKBACK = 2;
  const enc = (o) => btoa(unescape(encodeURIComponent(JSON.stringify(o))));
  const dec = (b) => JSON.parse(decodeURIComponent(escape(atob(b))));
  const say = (m) => S.log.push(m);

  const deposit = (e) => S.socket.send(JSON.stringify({ op: 'deposit', envelope: e }));

  // Tell the mailbox an envelope arrived, so it stops holding it.
  //
  // The Dart does this and so must anything claiming to mirror it, and there is
  // a second reason here: this harness deposits into the **production** mailbox.
  // Without a receipt every run left its envelopes sitting for the full
  // seven-day TTL under a tag derived from a phrase, which is litter in
  // somebody's live service and, run often enough, fills a tag.
  //
  // After the envelope is handled, never on arrival. Best effort: a receipt
  // that does not go means re-delivery, which is the harmless direction.
  const acknowledge = (e) => {
    try {
      S.socket.send(JSON.stringify({
        op: 'collected',
        digests: [window.rotelyx.receiptFor(e)],
      }));
    } catch (err) { /* re-delivery is recoverable; losing a message is not */ }
  };
  const subscribe = (t) => S.socket.send(JSON.stringify({ op: 'subscribe', tags: t }));
  const unsubscribe = (t) => S.socket.send(JSON.stringify({ op: 'unsubscribe', tags: t }));

  function resubscribe() {
    const now = S.session.myPollingTags(LOOKBACK);
    const fresh = now.filter((t) => !S.listening.includes(t));
    if (fresh.length) { subscribe(fresh); S.listening = S.listening.concat(fresh); }
  }

  function enterConversation() {
    // Guest stops listening at the meeting place; host stays so others can join.
    if (S.role === 'guest') unsubscribe([S.meeting]);
    S.joined = true;
    S.safety = S.session.safetyNumber();
    S.epoch = S.session.epoch;
    resubscribe();
    say('conversation established');
  }

  function onRendezvous(payloadB64) {
    const msg = dec(payloadB64);

    if (msg.t === 'hello' && S.role === 'host') {
      const first = !S.joined;
      const inv = S.session.invite(msg.keyPackage);
      if (first) {
        deposit(window.rotelyx.sealUnder(S.meeting, enc({
          t: 'welcome', name: 'host',
          welcome: inv.welcome, ratchetTree: inv.ratchetTree,
          pqCiphertext: S.session.encapsulateTo(msg.hybridPublicKey),
        })));
        deposit(window.rotelyx.sealUnder(S.meeting, enc({
          t: 'commit', commit: S.session.commitPq(),
        })));
        enterConversation();
      } else {
        deposit(window.rotelyx.sealUnder(S.meeting, enc({
          t: 'welcome', name: 'host',
          welcome: inv.welcome, ratchetTree: inv.ratchetTree,
        })));
        for (const e of S.session.sealCommitForGroup(inv.commit)) deposit(e);
        resubscribe();
        S.epoch = S.session.epoch;
      }
      return;
    }

    if (msg.t === 'welcome' && S.role === 'guest' && !S.joined) {
      S.session.join(msg.welcome, msg.ratchetTree);
      if (msg.pqCiphertext) S.session.openPq(msg.pqCiphertext);
      enterConversation();
      return;
    }

    if (msg.t === 'commit' && S.role === 'guest') {
      S.session.receive(msg.commit);
      S.epoch = S.session.epoch;
      // The epoch moved, so our tags moved with it. Without this the guest
      // keeps listening on the pre-commit tag set and every message the host
      // sends is addressed somewhere nobody is subscribed.
      resubscribe();
      say('post-quantum keys mixed in');
      return;
    }
  }

  function onConversation(envelopeB64) {
    let payload;
    try { payload = S.session.openMine(envelopeB64, LOOKBACK); }
    catch { return; }  // not ours in this window

    // `receive` answers with which of three things arrived, as JSON:
    // `{"kind":"message","text":...}`, `{"kind":"membership",...}` or
    // `{"kind":"nothing"}`. This read the result as the plaintext, from when
    // the engine returned that or nothing, so every message came back as an
    // object and matched no expected text. The Dart had the same bug once and
    // it was worse there: an object is not null, but the old check made it
    // null, and null means "a commit" to the caller, so Android dropped every
    // inbound message in silence.
    //
    // This file exists to mirror the Dart step for step, so a divergence here
    // is not cosmetic: it is the harness no longer testing what the client
    // does, while still reporting.
    const answer = S.session.receive(payload);
    S.epoch = S.session.epoch;
    if (answer === null || answer === undefined) { resubscribe(); return; }

    let parsed;
    try { parsed = JSON.parse(answer); }
    catch { S.err = 'receive did not answer with JSON: ' + answer; return; }

    if (parsed.kind === 'membership') { resubscribe(); return; }
    if (parsed.kind !== 'message') return;   // nothing, and nothing to do
    S.inbox.push(parsed.text);
  }

  return {
    get joined() { return S.joined; },
    get safety()  { return S.safety; },
    get epoch()   { return S.epoch; },
    get inbox()   { return S.inbox; },
    get log()     { return S.log; },
    get err()     { return S.err; },

    start(role, phrase, name) {
      try {
        S.role = role;
        S.session = window.rotelyx.newSession(name);
        S.meeting = window.rotelyx.rendezvousTag(phrase);
        if (role === 'host') S.session.found();

        S.socket = new WebSocket('wss://m1.telyx.me/mailbox');

        S.socket.onerror = () => { S.err = 'mailbox unreachable'; };
        S.socket.onmessage = (ev) => {
          const r = JSON.parse(ev.data);
          if (r.op === 'error') { S.err = r.message; return; }
          if (r.op !== 'envelope') return;

          // Route by tag, not by phase: the commit is deposited under the
          // meeting tag but arrives after the conversation exists.
          let rv = null;
          try { rv = window.rotelyx.openUnder(r.envelope, S.meeting); } catch {}
          if (rv !== null) { onRendezvous(rv); acknowledge(r.envelope); return; }
          onConversation(r.envelope);
          acknowledge(r.envelope);
        };

        S.socket.onopen = () => {
          subscribe([S.meeting]);
          if (role === 'guest') {
            deposit(window.rotelyx.sealUnder(S.meeting, enc({
              t: 'hello', name,
              keyPackage: S.session.keyPackage(),
              hybridPublicKey: S.session.hybridPublicKey(),
            })));
          }
        };
        return 'started';
      } catch (e) { S.err = String(e); return 'error: ' + e; }
    },

    send(text) {
      try {
        const ct = S.session.send(text);
        for (const e of S.session.sealForGroup(ct)) deposit(e);
        return true;
      } catch (e) { S.err = String(e); return false; }
    },
  };
})();
'ok';
