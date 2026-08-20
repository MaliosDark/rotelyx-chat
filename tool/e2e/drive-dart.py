#!/usr/bin/env python3
"""Pair two browser tabs through the real Dart service, against the real mailbox.

    python3 tool/e2e/drive-dart.py

# What this proves that nothing else does

`drive.py` drives `tool/e2e/pair.js`, a JavaScript reimplementation of the
handshake. It proves the protocol and the wasm bridge work. It cannot prove
`lib/rotelyx/rotelyx_service.dart` works, because that is not the code it runs:
it is a second implementation that happens to agree with the first.

This drives the Dart. `window.__rotelyx` is the same singleton the buttons call,
published by `lib/rotelyx/e2e.dart` when the build is given `--dart-define=e2e`.

The path exercised is the one the QR pairing added: a meeting code is minted,
both sides derive the same mailbox tag from it, and the handshake happens there.
Scanning a code and typing it reach this same call, so what is untested after
this passes is the camera, not the pairing.

# What it still does not prove

Nobody clicks anything. The widgets, their state and their wiring to this
service are what `integration_test/ui_test.dart` is for.
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "shots")
PORT = 8810
DRIVERS = {"a": "http://127.0.0.1:4480", "b": "http://127.0.0.1:4481"}
SID_DRIVER = {}

GREEN, RED, DIM, OFF = "\033[32m", "\033[31m", "\033[2m", "\033[0m"

# An empty inbox serialises to "[]", which is a non-empty string and so is
# truthy. Polling for the raw value returns immediately with nothing in it.
INBOX = ("var i = JSON.parse(window.__rotelyx.inbox());"
         "return i.length ? JSON.stringify(i) : null;")
results = []


def ok(what):
    results.append(True)
    print(f"  {GREEN}pass{OFF}  {what}")


def fail(what, detail=""):
    results.append(False)
    print(f"  {RED}FAIL{OFF}  {what}")
    if detail:
        print(f"        {DIM}{detail}{OFF}")


def call(method, path, body=None, base=None):
    if base is None:
        sid = path.split("/session/")[-1].split("/")[0] if "/session/" in path else None
        base = SID_DRIVER.get(sid, DRIVERS["a"])
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read())


def new_session(which):
    caps = {"capabilities": {"alwaysMatch": {
        "browserName": "firefox",
        "moz:firefoxOptions": {"args": ["-headless", "--width=520", "--height=940"]},
    }}}
    sid = call("POST", "/session", caps, base=DRIVERS[which])["value"]["sessionId"]
    SID_DRIVER[sid] = DRIVERS[which]
    return sid


def js(sid, script, args=None):
    return call("POST", f"/session/{sid}/execute/sync",
                {"script": script, "args": args or []})["value"]


def wait_for(sid, script, what, timeout=90):
    """Poll a predicate. Returns its value, or raises with what was last seen."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = js(sid, script)
        if last:
            return last
        time.sleep(0.5)
    raise RuntimeError(f"timed out waiting for {what} (last value: {last!r})")


def shot(sid, name):
    os.makedirs(OUT, exist_ok=True)
    png = call("GET", f"/session/{sid}/screenshot")["value"]
    path = os.path.join(OUT, f"{name}.png")
    with open(path, "wb") as f:
        f.write(base64.b64decode(png))
    return path


def main():
    build = os.path.join(ROOT, "build", "e2e")
    if not os.path.isdir(build):
        print("no build at build/e2e. Run:")
        print("  tool/dev/build-web.sh --dart-define=e2e=true -o build/e2e")
        return 1

    print(f"\nserving {DIM}build/e2e{OFF} on :{PORT}")
    server = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "tool", "e2e", "spaserve.py"), build, str(PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    drivers = [
        subprocess.Popen(["geckodriver", "--port", p.rsplit(":", 1)[1]],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for p in DRIVERS.values()
    ]
    time.sleep(7)

    a = b = None
    try:
        a, b = new_session("a"), new_session("b")
        for sid in (a, b):
            call("POST", f"/session/{sid}/timeouts", {"script": 60000})
            call("POST", f"/session/{sid}/url", {"url": f"http://127.0.0.1:{PORT}/"})

        print("\nboot")
        for sid, who in ((a, "Ana"), (b, "Beto")):
            wait_for(sid, "return !!window.__rotelyx", f"the Dart hook in {who}'s tab")
            wait_for(sid, "return window.rotelyx && window.rotelyx.ready === true",
                     f"the wasm in {who}'s tab")
        ok("both tabs reached the real Dart service")

        print("\npairing by meeting code, the path a QR scan takes")
        code = js(a, "return window.__rotelyx.newCode();")
        if len(code) == 29 and code.startswith("RTLX1"):
            ok(f"minted a meeting code  {DIM}{code}{OFF}")
        else:
            fail("meeting code is malformed", code)

        js(a, "window.__rotelyx.host(arguments[0], 'Ana');", [code])
        time.sleep(1.5)
        js(b, "window.__rotelyx.join(arguments[0], 'Beto');", [code])

        for sid, who in ((a, "Ana"), (b, "Beto")):
            try:
                wait_for(sid, "return window.__rotelyx.state() === 'joined'",
                         f"MLS to establish in {who}'s tab", 90)
                ok(f"{who} reached joined")
            except RuntimeError as e:
                fail(f"{who} never joined",
                     f"{e}\n        lastError: {js(sid, 'return window.__rotelyx.lastError();')}")
                shot(sid, f"dart-e2e-stuck-{who}")
                return 1

        print("\nidentity")
        sn_a = js(a, "return window.__rotelyx.safety();")
        sn_b = js(b, "return window.__rotelyx.safety();")
        if sn_a and sn_a == sn_b:
            ok(f"safety numbers match  {DIM}{sn_a}{OFF}")
        else:
            fail("safety numbers differ", f"{sn_a!r} vs {sn_b!r}")

        ep_a, ep_b = js(a, "return window.__rotelyx.epoch();"), js(b, "return window.__rotelyx.epoch();")
        if ep_a == ep_b:
            ok(f"same epoch  {DIM}{ep_a}{OFF}")
        else:
            fail("epochs differ", f"{ep_a} vs {ep_b}")

        n_a, n_b = js(a, "return window.__rotelyx.members();"), js(b, "return window.__rotelyx.members();")
        if n_a == 2 and n_b == 2:
            ok("both see a group of two")
        else:
            fail("member counts wrong", f"{n_a} and {n_b}")

        print("\nmessages, through the same send() the composer calls")
        js(a, "window.__rotelyx.send('hello from Ana');")
        try:
            got = wait_for(b, INBOX, "Beto to receive", 45)
            if "hello from Ana" in json.loads(got):
                ok("Ana to Beto")
            else:
                fail("Beto received something else", got)
        except RuntimeError as e:
            fail("Beto received nothing", str(e))

        js(b, "window.__rotelyx.send('and back from Beto');")
        try:
            got = wait_for(a, INBOX, "Ana to receive", 45)
            if "and back from Beto" in json.loads(got):
                ok("Beto to Ana")
            else:
                fail("Ana received something else", got)
        except RuntimeError as e:
            fail("Ana received nothing", str(e))

        print("\n" + DIM + f"screenshots: {shot(a, 'dart-e2e-ana')}, {shot(b, 'dart-e2e-beto')}" + OFF)

    finally:
        for sid in (a, b):
            if sid:
                try:
                    call("DELETE", f"/session/{sid}")
                except Exception:
                    pass
        for d in drivers:
            d.terminate()
        server.terminate()

    passed, total = sum(results), len(results)
    colour = GREEN if passed == total else RED
    print(f"\n{colour}{passed}/{total}{OFF} through the real Dart service\n")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
