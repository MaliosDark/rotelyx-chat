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

    const text = S.session.receive(payload);
    S.epoch = S.session.epoch;
    if (text === null || text === undefined) { resubscribe(); return; }
    S.inbox.push(text);
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

        S.socket = new WebSocket('wss://mail-rotelyx.ideoa.co/mailbox');

        S.socket.onerror = () => { S.err = 'mailbox unreachable'; };
        S.socket.onmessage = (ev) => {
          const r = JSON.parse(ev.data);
          if (r.op === 'error') { S.err = r.message; return; }
          if (r.op !== 'envelope') return;

          // Route by tag, not by phase: the commit is deposited under the
          // meeting tag but arrives after the conversation exists.
          let rv = null;
          try { rv = window.rotelyx.openUnder(r.envelope, S.meeting); } catch {}
          if (rv !== null) { onRendezvous(rv); return; }
          onConversation(r.envelope);
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
