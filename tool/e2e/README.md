# End-to-end harness

Drives the built app in headless Firefox and pairs two tabs against the real
mailbox. It has found two bugs that `flutter analyze`, `flutter test` and
`flutter build web` all passed:

- the guest never re-subscribed after the post-quantum commit moved the epoch,
  so pairing succeeded, safety numbers matched, and **no message ever arrived**
  in either direction
- with fonts unbundled and the CSP blocking the font CDN, the app rendered every
  control in the right place with **no text anywhere**

Both were invisible to every static check. Run this before believing a release.

## Why it is written this way

There is no selenium, playwright or chromium-cli here, and none is needed:
geckodriver speaks WebDriver over plain HTTP/JSON, so `drive.py` uses `urllib`.

Flutter renders through CanvasKit into a single `<canvas>`, so there is no DOM to
query and widgets cannot be clicked by selector. `pair.js` therefore drives
`window.rotelyx`, the same bridge `lib/rotelyx/rotelyx_service.dart` calls, and
mirrors the Dart handshake step for step. A divergence between the two is a real
finding, not a difference between harnesses.

geckodriver serves **one session per instance**, so two tabs need two instances.

## Running it

```bash
flutter build web --release --no-web-resources-cdn

(cd build/web && python3 -m http.server 8765 &)
nohup geckodriver --port 4444 --host 127.0.0.1 >/tmp/gecko1.log 2>&1 &
nohup geckodriver --port 4445 --host 127.0.0.1 >/tmp/gecko2.log 2>&1 &

python3 tool/e2e/drive.py
```

Screenshots land beside the script. **Look at them**, the no-text bug was a
clean pass on every assertion and an obviously broken screenshot.

Stop the background processes by port, not with `pkill -f`:

```bash
for p in 8765 4444 4445; do
  ss -lptn "sport = :$p" | grep -oP 'pid=\K[0-9]+' | head -1 | xargs -r kill
done
```

## What it asserts

1. the wasm bridge publishes `window.rotelyx`
2. `rotelyx-wasm` loads, reporting its protocol version and member cap
3. the Flutter canvas renders
4. no console errors
5. the MLS handshake completes through the blind mailbox
6. both sides derive the **same safety number**
7. both sides reach the same epoch after the post-quantum commit
8. host → guest message decrypts
9. guest → host message decrypts

It talks to production (`wss://m1.telyx.me/mailbox`) and leaves a
short-lived conversation there under a timestamped meeting phrase.
