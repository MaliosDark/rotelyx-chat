# The Content-Security-Policy, and the one thing it breaks

`web/index.html` carries a CSP whose `connect-src` names the mailbox and nothing
else. That is the mechanism behind "this client contacts no third party": if a
dependency ever tries to phone somewhere, the browser refuses and says so,
rather than the traffic leaving quietly.

It has caught real things during development, Flutter's CanvasKit reaching for
`fonts.gstatic.com`, `google_sign_in` loading `accounts.google.com/gsi/client`.
Both were blocked. Both would otherwise have shipped.

## What it breaks: `flutter run` and `flutter drive`

A debug build connects back to the Dart VM service over a WebSocket on a random
localhost port:

```
ws://127.0.0.1:45821/…
```

That is a **different port** from the one serving the page, so it is not
`'self'`, and `connect-src` refuses it. The symptom is not an error. The tool
prints

```
Waiting for connection from debug service on Chrome...
```

and waits forever, which reads as a hang and is a policy decision.

The same applies to `integration_test`: `integration_test/ui_test.dart` is
written and analyses clean, and it cannot run until this is handled.

## The fix, and why it is the right shape anyway

**Deliver the CSP as an HTTP header in production, not as a meta tag.**

The browser already tells us the meta tag is the wrong vehicle:

```
The Content Security Policy directive 'frame-ancestors' is ignored
when delivered via a <meta> element.
```

`frame-ancestors` is the directive that stops the app being framed for
clickjacking, and in a meta tag it does nothing at all. A header carries it.

nginx, alongside the `try_files` rule the path URL strategy needs:

```nginx
location / {
  try_files $uri $uri/ /index.html;

  add_header Content-Security-Policy "
    default-src 'self';
    script-src 'self' 'wasm-unsafe-eval';
    style-src 'self' 'unsafe-inline';
    img-src 'self' data: blob:;
    media-src 'self' data: blob:;
    font-src 'self';
    connect-src 'self' blob: data: wss://mail-rotelyx.ideoa.co;
    frame-ancestors 'none';
    base-uri 'self';
    form-action 'none';
  " always;
}
```

With the policy in the header, the meta tag comes out of `index.html`, and a
debug build, served by Flutter's own dev server, which sets no such header -
connects normally.

Production is *stronger* after this change, not weaker: `frame-ancestors`
starts working.

## Until then

Development works against a release build:

```bash
flutter build web --release --no-web-resources-cdn
python3 tool/e2e/spaserve.py "$PWD/build/web" 8766
```

and `tool/e2e/drive.py` exercises the protocol end to end against it. What that
cannot reach is the widget layer, which is what `integration_test/` is for and
what remains unverified by anything that clicks.

## The gap this exists to close, and the one the test cannot

Worth stating plainly, because it is the reason both the policy above and
`test/no_foreign_infrastructure_test.dart` exist and why neither is enough
alone.

Two third-party calls in this application never appeared in any source file.
They live below that line, in Flutter's own engine, and only showed up when the
compiled bundle was scanned:

**CanvasKit from `www.gstatic.com`.** Flutter Web's bootstrap fetches its
renderer from Google unless `useLocalCanvasKit` is set. The 19 MB local copy is
written into the build output regardless and simply goes unused, so the leak is
invisible from a file listing: the directory is right there. Fixed by building
with `--no-web-resources-cdn`, which `tool/dev/build-web.sh` enforces and then
verifies in the emitted `flutter_bootstrap.js`.

**Fonts from `fonts.gstatic.com`.** The renderer fetches them on demand and no
build flag disables it, so `font-src 'self'` blocks it instead.

Blocking it was correct and it broke the application. CanvasKit cannot see
platform fonts, so with the CDN closed and nothing bundled there was no font at
all: every control painted in the right place with **no text anywhere**. Fixed
by bundling DejaVu Sans, Lohit Devanagari and KacstOne under `assets/fonts/`,
which is the price of not asking Google for glyphs.

`flutter analyze`, `flutter test` and `flutter build web` all passed on the
version that rendered no text. Only opening it in a browser and looking at the
screenshot caught it.

**The lesson generalises.** "The source names no foreign host" and "the
application contacts no foreign host" are different claims, and the gap between
them is the framework. `test/no_foreign_infrastructure_test.dart` guards the
first. Only reading the built bundle establishes the second, which is why
`tool/dev/build-web.sh` greps the output rather than trusting the flag it just
passed.
