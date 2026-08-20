"""Drive Rotelyx Chat in headless Firefox through raw WebDriver.

No selenium on this machine, and none needed: geckodriver speaks WebDriver over
plain HTTP/JSON.

Flutter renders through CanvasKit into a single <canvas>, so there is no DOM to
query and clicking widgets by selector is not available. That turns out not to
matter for what needs proving: `execute_script` reaches the same
`window.rotelyx` bridge the Dart code calls, so the handshake can be driven
directly against the real mailbox, which tests the transport rather than the
button that triggers it.
"""

import base64, json, sys, time, urllib.request

DRIVERS = {"a": "http://127.0.0.1:4444", "b": "http://127.0.0.1:4445"}
SID_DRIVER = {}
APP = "http://127.0.0.1:8765/index.html"
OUT = __import__('os').path.dirname(__import__('os').path.abspath(__file__))


def call(method, path, body=None, base=None):
    if base is None:
        # Route by session id: geckodriver serves one session per instance, so
        # two tabs mean two drivers.
        sid = path.split("/session/")[-1].split("/")[0] if "/session/" in path else None
        base = SID_DRIVER.get(sid, DRIVERS["a"])
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def new_session(which):
    caps = {"capabilities": {"alwaysMatch": {
        "browserName": "firefox",
        "moz:firefoxOptions": {"args": ["-headless"]},
    }}}
    sid = call("POST", "/session", caps, base=DRIVERS[which])["value"]["sessionId"]
    SID_DRIVER[sid] = DRIVERS[which]
    return sid


def js(sid, script, args=None):
    return call("POST", f"/session/{sid}/execute/sync",
                {"script": script, "args": args or []})["value"]


def goto(sid, url):
    call("POST", f"/session/{sid}/url", {"url": url})


def screenshot(sid, name):
    png = call("GET", f"/session/{sid}/screenshot")["value"]
    path = f"{OUT}/{name}.png"
    open(path, "wb").write(base64.b64decode(png))
    return path


def wait_for(sid, script, what, timeout=60):
    """Poll a JS predicate. Returns the value, or raises with what was seen."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = js(sid, script)
        if last:
            return last
        time.sleep(0.5)
    raise RuntimeError(f"timed out waiting for {what} (last value: {last!r})")


def main():
    results = []

    def ok(label, detail=""):
        results.append(("PASS", label, detail))
        print(f"  PASS  {label}  {detail}")

    def fail(label, detail=""):
        results.append(("FAIL", label, detail))
        print(f"  FAIL  {label}  {detail}")

    a = new_session("a")
    b = new_session("b")
    print(f"sessions: {a[:8]} / {b[:8]}\n")

    try:
        # ---- load ----------------------------------------------------------
        for sid, tag in ((a, "A"), (b, "B")):
            goto(sid, APP)
        print("loading the app in two tabs...")

        for sid, tag in ((a, "A"), (b, "B")):
            wait_for(sid, "return !!(window.rotelyx)", f"window.rotelyx in {tag}")
        ok("the wasm bridge is published as window.rotelyx")

        info = js(a, "return {ready: window.rotelyx.ready, version: window.rotelyx.version,"
                     " maxMembers: window.rotelyx.maxMembers, error: window.rotelyx.error||null};")
        if info.get("ready"):
            ok("rotelyx-wasm loaded",
               f"protocol {info['version']}, maxMembers {info['maxMembers']}")
        else:
            fail("rotelyx-wasm loaded", f"error: {info.get('error')}")
            raise SystemExit(1)

        # ---- the Flutter UI actually painted -------------------------------
        wait_for(a, "return document.querySelector('flt-glass-pane, flutter-view, canvas') !== null",
                 "the Flutter canvas")
        ok("the Flutter interface rendered")
        print(f"        screenshot: {screenshot(a, 'pairing')}")

        # ---- console errors ------------------------------------------------
        # Anything the CSP refused shows up here, which is the point. Two of
        # those refusals are the policy working exactly as designed and will
        # never stop happening: CanvasKit asks `fonts.gstatic.com` for Roboto on
        # every load, there is no build flag that stops it, and `font-src
        # 'self'` says no. Fonts are bundled precisely so that refusal is
        # harmless.
        #
        # Counting them as a failure meant this harness reported 8 of 9 on a
        # completely healthy run, every run, which is how a suite stops being
        # read. Expected refusals are named and excluded; anything else fails.
        expected = ("fonts.gstatic.com", "gstatic.com/flutter-canvaskit")
        errs = [e for e in js(a, "return (window.__errs||[]).slice(0,40);")
                if not any(x in e for x in expected)]
        if errs:
            fail("console clean apart from the fonts the CSP blocks",
                 json.dumps(errs)[:300])
        else:
            ok("console clean apart from the fonts the CSP blocks")

        # ---- the real handshake, against the production mailbox ------------
        print("\npairing against wss://mail-rotelyx.ideoa.co/mailbox ...")

        driver_js = open(f"{OUT}/pair.js").read()
        js(a, driver_js)
        js(b, driver_js)

        phrase = "prueba-rotelyx-" + str(int(time.time()))
        js(a, "return window.__rx.start('host', arguments[0], 'Ana');", [phrase])
        time.sleep(1.5)
        js(b, "return window.__rx.start('guest', arguments[0], 'Beto');", [phrase])

        for sid, tag in ((a, "A/host"), (b, "B/guest")):
            wait_for(sid, "return window.__rx.joined === true", f"MLS to establish in {tag}", 60)
        ok("MLS handshake completed through the blind mailbox")

        sn_a = js(a, "return window.__rx.safety;")
        sn_b = js(b, "return window.__rx.safety;")
        if sn_a and sn_a == sn_b:
            ok("safety numbers match", sn_a)
        else:
            fail("safety numbers match", f"A={sn_a!r} B={sn_b!r}")

        ep_a = js(a, "return window.__rx.epoch;")
        ep_b = js(b, "return window.__rx.epoch;")
        if ep_a == ep_b and ep_a >= 2:
            ok("same epoch after the post-quantum commit", f"epoch {ep_a}")
        else:
            fail("same epoch after the post-quantum commit", f"A={ep_a} B={ep_b}")

        # ---- messages both ways --------------------------------------------
        js(a, "window.__rx.send('hello from Ana');")
        got = wait_for(b, "return window.__rx.inbox.length ? window.__rx.inbox[0] : null",
                       "the message to reach B", 45)
        if got == "hello from Ana":
            ok("host to guest, decrypted", repr(got))
        else:
            fail("host to guest, decrypted", repr(got))

        js(b, "window.__rx.send('and back from Beto');")
        got = wait_for(a, "return window.__rx.inbox.length ? window.__rx.inbox[0] : null",
                       "the message to reach A", 45)
        if got == "and back from Beto":
            ok("guest to host, decrypted", repr(got))
        else:
            fail("guest to host, decrypted", repr(got))

        print(f"\n        final screenshot: {screenshot(a, 'after-pairing')}")

    except Exception as e:
        fail("ejecucion", f"{type(e).__name__}: {e}")
    finally:
        for sid in (a, b):
            try: call("DELETE", f"/session/{sid}")
            except Exception: pass

    print("\n" + "=" * 60)
    passed = sum(1 for r in results if r[0] == "PASS")
    failed = sum(1 for r in results if r[0] == "FAIL")
    print(f"{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
