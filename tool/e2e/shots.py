#!/usr/bin/env python3
"""Capture screenshots of individual surfaces through raw WebDriver.

CanvasKit draws the whole application into one canvas, so there are no DOM
elements to click and no way to walk to a screen from outside. The way in is the
compile-time fixtures in `lib/ui/app.dart` and `lib/ui/screens/pair.dart`, which
build a release that opens directly on one surface. This script serves each of
those builds and photographs it.

The camera is a fake one supplied by Firefox itself, through
`media.navigator.streams.fake`. That proves the permission prompt, the platform
view and the preview all work without needing a real camera, and without any of
it leaving the machine.

    python3 tool/e2e/shots.py
"""

import base64
import http.server
import json
import os
import subprocess
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "shots")
DRIVER = "http://127.0.0.1:4455"

# Each build gets its own port. Serving them all on one port would hand the
# browser the same URL three times, and it would answer the second and third
# from cache: three photographs of the first screen.
SHOTS = [
    ("unlock", "shot-unlock", 8791, 2.5),
    ("pair-qr", "shot-pairqr", 8792, 7.0),
    ("scan", "shot-scan", 8793, 9.0),
]


def serve(directory, port):
    """A static server that falls back to index.html, as the app needs."""

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=directory, **kw)

        def log_message(self, *a):
            pass

        def send_head(self):
            path = self.translate_path(self.path)
            if not os.path.exists(path):
                self.path = "/index.html"
            return super().send_head()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        DRIVER + path, data=data, method=method,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def main():
    os.makedirs(OUT, exist_ok=True)

    driver = subprocess.Popen(
        ["geckodriver", "--port", "4455"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)

    try:
        session = call("POST", "/session", {"capabilities": {"alwaysMatch": {
            "browserName": "firefox",
            "moz:firefoxOptions": {
                "args": ["-headless", "--width=520", "--height=1000"],
                "prefs": {
                    # A synthetic camera, granted without a prompt. Nothing
                    # real is recorded and nothing leaves this machine.
                    "media.navigator.streams.fake": True,
                    "media.navigator.permission.disabled": True,
                },
            },
        }}})["value"]["sessionId"]

        call("POST", f"/session/{session}/window/rect",
             {"width": 520, "height": 1000, "x": 0, "y": 0})

        for name, build, port, settle in SHOTS:
            directory = os.path.join(ROOT, "build", build)
            if not os.path.isdir(directory):
                print(f"  {name}: no build at {directory}, skipped")
                continue

            server = serve(directory, port)
            try:
                call("POST", f"/session/{session}/url",
                     {"url": f"http://127.0.0.1:{port}/"})
                time.sleep(settle)
                png = call("GET", f"/session/{session}/screenshot")["value"]
                path = os.path.join(OUT, f"{name}.png")
                with open(path, "wb") as f:
                    f.write(base64.b64decode(png))
                # web/diag.js records anything the page logged or threw. A
                # blank screenshot with an empty list here means slow, and a
                # blank one with entries means broken.
                errs = call("POST", f"/session/{session}/execute/sync",
                            {"script": "return (window.__errs||[]).slice(-12)",
                             "args": []})["value"]
                print(f"  {name}: {path}")
                for e in errs or []:
                    if "log:" not in e[:5]:
                        print(f"      {e[:200]}")
            finally:
                server.shutdown()
                server.server_close()
                time.sleep(0.3)

        call("DELETE", f"/session/{session}")
    finally:
        driver.terminate()


if __name__ == "__main__":
    main()
