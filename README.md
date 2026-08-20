<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/images/rotelyx-lockup-dark.png">
  <img src="assets/images/rotelyx-lockup-light.png" alt="Rotelyx" height="52">
</picture>

# Rotelyx Chat

A Flutter chat client by **Ideoa Labs**, speaking the Rotelyx protocol.

Package: `rotelyx_chat` · Bundle ID: `com.ideoalabs.rotelyx`

---

> **Rotelyx is unaudited and pre-release. Do not use it to protect anything.**
> It makes no security claims until the review gates in the protocol
> repository's `docs/THREAT-MODEL.md` section 5 are met. The pairing screen says
> so too, on purpose: a client that looks finished is itself a security claim.

---

## What this is

A messenger with no account, no phone number and no directory. Two people start
a conversation by arriving at the same place rather than by looking each other
up, because there is nowhere to look anyone up.

`docs/HOW-IT-WORKS.md` explains the whole model from nothing, and is the right
place to start if any of the above sounds strange.

Messages go through `rotelyx-wasm`: MLS with a hybrid post-quantum key schedule,
sealed into padded envelopes and left in a blind mailbox.

## Where it stands

| | |
|---|---|
| Client source | about 15,900 lines under `lib/`, 72 files |
| Runtime dependencies | 4: `web`, `ffi`, `get_storage`, `qr_flutter` |
| Targets | web and Android build here; iOS, Linux, macOS and Windows are scaffolded |
| Tests | 127, all passing |
| Outbound addresses | 2, both ours |
| Third-party services | none |

**Working:** pairing by QR, phrase or invitation, with the camera reading the
code on a phone; one-to-one and group conversations; replies; reactions;
self-destructing messages that burn on both devices from the moment the
recipient reads them; encrypted local history; attachments up to 5 MB; unread
counts; a read tick that is never inferred; contact names, pictures, pinning and
muting; notifications with the sender's name and picture and no push service
involved; a PIN for the application; safety numbers; light and dark themes.

**Calls:** built and relayed, keyed from the same MLS group as the messages.
Each part is tested; they have not yet been run together on two phones.

Pairing and messaging are verified end to end through the real client against the
production mailbox, not through a stand-in: `tool/e2e/drive-dart.py`, 9 of 9.

**And on a phone.** A Note 58 on Android 16 hosts a meeting place, a browser
joins it, and a message crosses from one to the other and is still there when
the conversation is opened afterwards. One side runs the WebAssembly build and
the other the native library. See `docs/NATIVE.md`.

## Third-party contact: none

The whole live codebase opens exactly two outbound addresses, and they are the
same service in two environments:

```
wss://mail-rotelyx.ideoa.co/mailbox     production
ws://127.0.0.1:3341/mailbox             local development
```

There is no analytics, no crash reporter, no advertising identifier, no font
CDN, no link previewer fetching URLs out of incoming messages, and no push
service. Not switched off: absent.

`web/index.html` carries a Content-Security-Policy whose `connect-src` names the
mailbox explicitly. If a dependency ever tries to phone somewhere else, the
browser blocks it rather than the traffic leaving quietly.

`test/no_foreign_infrastructure_test.dart` scans the sources for hosts outside
the allowlist, including ones that would never actually be fetched. That is the
right level for a property this easy to lose by accident: a dependency adds a
telemetry ping, somebody pastes a CDN link in to fix a font, and nothing fails.

## Architecture

```
web/rotelyx/            rotelyx_wasm.js + .wasm, served from this origin
web/rotelyx_bridge.js   loads the ES module, owns the BigInt conversions
web/diag.js             error capture, external because the CSP blocks inline

lib/rotelyx/
  rotelyx_wasm.dart     facade over engine/, keeping the names the service uses
  engine/api.dart       what the engine offers, in ordinary Dart
  engine/backend.dart   one line, picking an implementation at compile time
  engine/web.dart       the wasm module through the JS bridge
  engine/native.dart    librotelyx_mobile through dart:ffi
  engine/call_native.dart  the codec, six C functions, no JSON per frame
  engine/net_native.dart   the QUIC connection a call runs on
  mailbox_client.dart   deposit / subscribe / unsubscribe, over platform/socket
  e2e.dart              the test hook, web only, behind a compile-time define
  rotelyx_service.dart  identity, pairing handshake, message flow
  rotelyx_store.dart    encrypted local history, the only copy that exists
  rotelyx_config.dart   endpoints; no Default, no environment override
  meeting_code.dart     the 29-character string a QR carries
  attachment.dart       files as messages, 5 MB, marker-prefixed
  quoted.dart           a reply, carrying its own excerpt
  ephemeral.dart        a message that expires, and what identifies it
  burn_clock.dart       when each side's countdown starts, and why it is one event
  signal.dart           receipts, reactions, pictures, call signalling
  alerts.dart           whether to interrupt somebody
  lock.dart             the application PIN, and what it does not protect
  passphrase.dart       generating one, with the entropy stated
  calls.dart            placing, ringing, answering, hanging up
  call_state.dart       who may do which of those, and when
  call_loop.dart        the twenty millisecond loop a call is made of
  push.dart             waking a device, and why the token carries no tag

lib/platform/           what a browser does that a phone does not, and back
  socket*.dart          package:web WebSocket, or dart:io's
  host*.dart            URL strategy and the boot screen, or nothing
  file_pick*.dart       an <input type=file>, or the system document picker
  notify*.dart          the Notification API, or a channel to Android
  call_audio.dart       the microphone and speaker, in 20 ms frames
  apple_push*.dart      registering with Apple, or nothing

lib/qr/                 a QR reader written here rather than imported
  tables.dart           the standard's block and alignment tables
  decode.dart           modules to text: format, mask, layout, Reed-Solomon
  detect.dart           camera frame to modules: binarise, locate, sample
  camera*.dart          getUserMedia, or CameraX through a texture

lib/ui/
  app.dart              the shell and its surfaces, no router
  theme.dart            the design system
  widgets.dart          buttons, fields, chips, notes
  brand.dart            the logo, and the QR that carries it
  gestures.dart         swipe from the edge, pull for settings
  burn.dart             the fire, and the shader that draws it
  screens/unlock.dart   whether this device keeps anything
  screens/pin.dart      the PIN, on a keypad that does not move
  screens/home.dart     two panes, collapsing below 900 px
  screens/pair.dart     QR, phrase, or invitation
  screens/scan.dart     the camera, with a typed fallback always present
  screens/chat.dart     the conversation, safety number on the wall
  screens/contact.dart  their name, picture, and what this device does about them
  screens/call.dart     a call, ringing or in progress
  screens/settings.dart
```

The handshake exists once, in `rotelyx_service.dart`. The JS bridge holds none
of it, so the two cannot drift.

There is no router. The app has four surfaces, and on the web a route carrying a
conversation id would put that id in browser history, which is the kind of trace
this application exists not to leave.

## Pairing

Rotelyx has no identity registry, so there is nothing to look anyone up in.
Three modes, all of which solve only the problem of where to put the first
message.

- **QR code**: one side shows, the other scans. The symbol carries a
  29-character meeting code, 120 random bits in a base32 alphabet, which both
  sides hash to the same mailbox tag. Not guessable.
- **Meeting phrase**: both sides type the same phrase. Same mechanism, weaker
  input: a phrase a person invented can be guessed by somebody who knows them.
- **Invitation code**: one side generates a block carrying its key package and a
  random 32-byte return tag, pasted through some other application.

**The QR cannot carry the invitation, and the reason is arithmetic.** An X-Wing
public key is 1216 bytes; with the MLS key package and two layers of base64 an
invitation runs to about 3000 characters. A QR tops out at 2953 bytes, and only
at the weakest correction level, at 177 modules across. So the QR carries an
address and the keys go over the mailbox, where their size costs nothing.

None of the three authenticates anybody. **Compare the safety number out of
band.** It is on the chat screen rather than behind a menu, because hidden
behind two taps it does not get compared.

Groups work by the host continuing to listen at the meeting place after the
first person arrives, so later arrivals are admitted up to the protocol's member
cap.

## Reading QR codes

Every Flutter QR scanner that supports the web fetches a JavaScript decoder from
a content delivery network at runtime. The Content-Security-Policy refuses that,
correctly. Rather than open a hole for one feature, `lib/qr/` decodes the symbol
here: binarise per eight-by-eight block, locate the three corner squares by their
1:1:3:1:1 run, fit a projective transform through the alignment square, sample
five points per module and vote, then undo the mask, the interleave and the
Reed-Solomon.

It is tested rather than assumed:

| Test | What it establishes |
|---|---|
| All 40 versions by all 4 correction levels, round trip | The tables and the arithmetic are right |
| 72 rotations, 0 to 355 degrees | Orientation does not matter |
| A 40 percent foreshortened pose | Reads when held off to one side |
| Blur, sensor noise, a lighting gradient | Reads on a poor camera in poor light |
| Pure noise, 52 frames | Never invents a reading |
| A screenshot of the running application | What the app draws can actually be scanned |

Measured over 400 random codes in the most severe pose, one failed: 99.75
percent per frame, against a camera examining eight frames a second. The pinned
codes in `test/meeting_code_test.dart` keep that assertion deterministic, and
the tail is written down rather than rediscovered as a flake.

The logo sits in the middle because the highest correction level can lose 30
percent of the symbol and still decode. The plate is 24 percent of the width,
under 6 percent of the area, and the same test destroys exactly that square and
decodes anyway, so the margin is measured and not hoped for.

## Local storage

The mailbox keeps nothing. An envelope is removed when collected and what is
never collected expires. There is no server-side history, no account to restore
from, and no other device holding a copy. **If this store loses a conversation,
the conversation is gone.**

Two blobs per conversation, both sealed under a key derived from the user's
passphrase with Argon2id at 64 MiB:

- the **session**, which is MLS group state, re-sealed after every send and
  every receive because the ratchet turns on both;
- the **log**, which is readable message text.

The second is the significant one. Everywhere else plaintext exists only in
memory, for the moment it is on screen. A conversation kept across restarts is a
conversation written down: encrypted, but written down, in a profile directory
that can be copied.

So keeping history is **opt in**, and turning it on asks for a passphrase rather
than inventing one. Without a passphrase the app still works and simply forgets
on reload, which is the stronger position and an inconvenient default.

`docs/PERSISTENCE.md` records what the protocol repository had to expose for
this to be possible.

## Not built yet

- **Calls between two phones.** Every part is built and tested on its own: audio
  crosses the codec between two members of a group, a datagram crosses the relay
  between two endpoints, and the state machine holds up against signals that
  arrive out of order. The three have not yet been run together on two devices,
  which is where this kind of thing fails.
- **Calls in a browser.** QUIC datagrams are native only, so a tab cannot carry
  one. Text still works there; a call does not.
- **The camera, the file picker and audio on iOS.** All three are platform
  channels and all three are written for Android only. On iOS the scanner falls
  back to typing a code, which works, and the attachment button says so rather
  than opening nothing.
- **Push on iOS.** The client side is built: registration with Apple, the
  mailbox frames, and a notification service extension. What remains is the
  mailbox sending the push and five steps that need a Mac. `docs/PUSH.md`.
  Android needs none of it and uses none of it.
- **Direct peer to peer in a browser.** `rotelyx-wasm` is the message layer.
  Transport is native only, so every browser message goes through the mailbox.
- **A conversation lock.** The application PIN is built. Locking one
  conversation is a different thing: it has to seal that conversation under a
  key derived from the PIN as well as the passphrase, or it is a curtain with a
  padlock painted on it.
- **Group read receipts.** The tick says somebody read it, not everybody.

## Running it

### Android

```bash
tool/native/build-android.sh     # the Rust engine, release, all three ABIs
flutter build apk                # or --split-per-abi for a phone-sized one
```

`docs/NATIVE.md` covers what the script does and why it defaults to release.
iOS is `tool/native/build-ios.sh`, which needs a Mac, plus two steps in Xcode
that the script prints.

### Web

```bash
flutter pub get
flutter run -d chrome

flutter build web --release --no-web-resources-cdn   # note the flag
python3 tool/e2e/spaserve.py "$PWD/build/web" 8766
```

Open two tabs, create an invitation or a meeting code in one, and use it in the
other.

### `--no-web-resources-cdn` is not optional

Flutter Web is itself a third-party caller by default. Its bootstrap decides
where to fetch the CanvasKit renderer like this:

```js
canvasKitBaseUrl ? canvasKitBaseUrl
  : (engineRevision && !useLocalCanvasKit)
    ? "https://www.gstatic.com/flutter-canvaskit/" + engineRevision
    : "canvaskit"
```

The 19 MB `canvaskit/` directory ships in the build output either way. Without
the flag it is simply **not used**, and every page load fetches the renderer
from Google instead. The flag sets `useLocalCanvasKit: true`. The gstatic string
still appears in the bundle afterwards, as the dead branch of that ternary.

Verified against the compiled output rather than the source: `main.dart.js`
names `mail-rotelyx.ideoa.co` and nothing else reachable.

### The server must rewrite unknown paths to `index.html`

A plain static server returns **404** for any path that is not a file. The app
works until somebody reloads the page, which is the worst time to find out.

```nginx
location / {
  try_files $uri $uri/ /index.html;
}
```

`tool/e2e/spaserve.py` does the same for development.

### Fonts have to be bundled, and this is not cosmetic

Flutter's CanvasKit renderer fetches fonts from `https://fonts.gstatic.com/s/`
on demand. There is no build flag to stop it, so `font-src 'self'` in the CSP
blocks it instead, correctly, since that request tells Google who is reading
what.

The consequence is more severe than a substituted typeface. **CanvasKit cannot
see platform fonts at all.** With nothing bundled and the CDN blocked there is
no font to fall back to, and the application renders every layout perfectly with
*no text anywhere*. Nothing in `flutter analyze`, `flutter test` or
`flutter build` reports that, which is why the fonts below are not optional.

`assets/fonts/` therefore carries:

| Font | Scripts | Licence |
|---|---|---|
| DejaVu Sans (regular, bold) | Latin, Cyrillic, Greek | free (Bitstream Vera derivative) |
| Lohit Devanagari | Devanagari | OFL |
| KacstOne | Arabic | GPL |

Declared as `RotelyxSans` with `fontFamilyFallback`, applied at the theme in
`lib/ui/theme.dart` so a `TextStyle` that forgets to name a family still
resolves. Flutter walks the fallback list per glyph, so each script picks up its
own face without the surrounding Latin text changing typeface.

The interface is English only, so the fallbacks matter for message content
rather than for the interface. **Hangul is not covered.** Covering it needs a
subsetted Noto Sans KR: the full-Hangul fonts on a typical Linux box are 19 MB
CJK collections, and the smaller candidates cover part of the syllable range and
show boxes for the rest.

Substituting Manrope, which the design was drawn in, is a file swap in
`assets/fonts/` and a rename in `pubspec.yaml`. No code changes.

## Keeping the wasm in step

`web/rotelyx/` is a **copy** of `site/rotelyx/` from the protocol repository and
does not rebuild itself. After every `wasm-pack` build there:

```bash
cp ../comms-real-e2e/site/rotelyx/rotelyx_wasm.js \
   ../comms-real-e2e/site/rotelyx/rotelyx_wasm_bg.wasm \
   web/rotelyx/
```

A stale copy is worth catching early, because it does not announce itself: the
old build loads and pairs, and only fails when it tries to talk to a client on
the current message path.

Two things make that visible rather than silent. The bridge in
`web/rotelyx_bridge.js` and the bindings in `lib/rotelyx/rotelyx_wasm.dart` name
every method they use, so a removed export is a missing-method error. And
`tool/dev/build-web.sh` refuses to register a service worker, so a browser never
answers from a build it cached.

## Testing

Five levels, because each catches something the one below it cannot.

**`flutter test`**, 127 tests across 19 files, in about thirty seconds. The
engine and transport tests need the native library on the loader path:

```bash
LD_LIBRARY_PATH="$PWD/build/native" flutter test
```

| File | What it covers |
|---|---|
| `qr_decode_test.dart` | The decoder, over all 160 version and level combinations |
| `qr_detect_test.dart` | Finding a code in a frame: rotation, perspective, blur, noise |
| `meeting_code_test.dart` | Minting, parsing, and the logo's error-correction budget |
| `rendered_qr_test.dart` | A screenshot of the running app, read by the real decoder |
| `no_foreign_infrastructure_test.dart` | No host outside the allowlist, no overridable endpoint |
| `native_engine_test.dart` | The FFI engine: pairing, sealing, a message across |
| `call_test.dart` | A call between two members, with audio crossing the codec |
| `transport_test.dart` | Two endpoints and a datagram, through a real relay |
| `call_state_test.dart` | Ringing and answering, against signals that arrive out of order |
| `burn_clock_test.dart` | Which side's countdown starts when |
| `ephemeral_test.dart`, `quoted_test.dart`, `signal_test.dart` | The wire formats |
| `store_ephemeral_test.dart` | That nothing reaches disk without a passphrase |
| `lock_test.dart` | The PIN, its attempt limit, and what survives a restart |
| `contact_layer_test.dart` | Names, receipts and reactions, and what they may not say |
| `push_test.dart` | That a wake registration names a device and nothing else |
| `passphrase_test.dart` | The generator, and the entropy it claims |
| `widget_test.dart` | That the application assembles a frame, at three widths |

**`tool/e2e/drive-dart.py`**: pairs two headless Firefox tabs through
`RotelyxService` itself, against the production mailbox, over the meeting-code
path a QR scan takes. Nine checks: the hook, the code, both sides joining,
matching safety numbers, a shared epoch, a group of two, and a message each way.

```bash
tool/dev/build-web.sh --dart-define=e2e=true -o build/e2e
python3 tool/e2e/drive-dart.py
```

`lib/rotelyx/e2e.dart` publishes the singleton as `window.__rotelyx` when that
define is passed, and is tree-shaken out of any build without it. Verified by
grepping the compiled output, not by assuming.

**Why it exists.** A harness that reimplements the protocol in JavaScript tests the protocol, not the client. This one drives `RotelyxService` itself, so a defect in the Dart has somewhere to show up.

**`tool/e2e/drive.py`**: the older harness, driving `tool/e2e/pair.js` through
`window.rotelyx`. It exercises the protocol and the wasm bridge rather than the Dart. Keep it: it is the control, and when the two harnesses disagree the disagreement is the finding.

It expects two geckodriver instances already listening on 4444 and 4445, and the
app served on 8765.

**`tool/e2e/shots.py`**: photographs individual surfaces by building them with a
compile-time fixture, since CanvasKit draws the whole app into one canvas and
there is nothing in the DOM to click. It supplies a synthetic camera through
Firefox's own `media.navigator.streams.fake`, so the scanner screen can be
verified without a device.

**`integration_test/ui_test.dart`**: drives the real widgets, so
`RotelyxService` and the `dart:js_interop` bindings are the code under test
rather than a JavaScript mirror of them. **Needs Chrome, and has never produced
a verdict in this environment.**

```bash
flutter drive --driver=test_driver/integration_test.dart \
              --target=integration_test/ui_test.dart -d chrome
```

Firefox does not work, and the reason is worth recording because the failure
looks like a hang. On the `web-server` device a debug build waits for a debugger
to attach before running `main()`, and attaching needs the Dart Debug Extension,
which is Chrome-only. Everything else succeeds, 372 DDC modules load,
`window.rotelyx` reports ready, and `document.body` simply stays empty.

`tool/dev/run-ui-test.sh` swaps the CSP out for the duration of a driven test
and restores it on exit, because `connect-src` blocks the debug service's
WebSocket on its random localhost port. `docs/CSP.md` explains why delivering
the policy as a header in production fixes this properly, and makes production
stronger at the same time.

### Why two browser harnesses rather than one

`tool/e2e/pair.js` mirrors `RotelyxService` step for step but is not that code.
It proves the protocol and the wasm bridge work; it cannot prove the Dart does.
The integration test closes that gap and is far slower. Keeping both means the
fast one can run on every change.

## Documentation

| File | Subject |
|---|---|
| `docs/SCREENS.md` | The application screen by screen, photographed on a phone |
| `docs/HOW-IT-WORKS.md` | The whole model from nothing. Start here |
| `docs/BACKLOG.md` | What is asked for, what is built, and what was refused and why |
| `docs/NATIVE.md` | Android and iOS: how the platform split works and how to build it |
| `docs/CSP.md` | The policy, and the one thing it breaks |
| `docs/PERSISTENCE.md` | What storing MLS state safely actually costs |
| `docs/PUSH.md` | Waking a device without re-linking rotating tags |
| `docs/RELEASING.md` | Everything both stores check, and what is not done yet |
| `docs/JURISDICTIONS.md` | Where this can be listed, and where it cannot |

## Brand assets

Everything the client shows is derived from two files in the protocol
repository, `docs/brand/rotelyx-logo-{dark,light}.png` and
`docs/brand/rotelyx-mark.png`. Nothing is drawn by hand and nothing is edited in
place:

```bash
python3 tool/brand/build.py
```

| Asset | Where it appears |
|---|---|
| `rotelyx-wordmark-{dark,light}.png` | Unlock screen, empty conversation pane |
| `rotelyx-lockup-{dark,light}.png` | Title bars, where the vertical lockup would put the word at four pixels |
| `rotelyx-mark.png` | The plate inside a QR code, and anywhere too small for the word |
| `web/rotelyx-boot.png` | The boot screen, outside the Flutter bundle on purpose |
| `web/favicon.png`, `web/icons/*` | Browser tab and installed application |

`-dark` means *for dark surfaces*, so it is the light-on-dark artwork. Getting
that backwards produces a logo that is invisible rather than wrong, which is
harder to catch in a screenshot than it sounds.

### There is no service worker, and removing one is part of the boot

`web/flutter_bootstrap.js` is written out rather than generated, for one reason:
the generated bootstrap always emits

```js
_flutter.loader.load({ serviceWorkerSettings: { serviceWorkerVersion: "..." } })
```

and `--pwa-strategy=none` does not change that. It empties
`flutter_service_worker.js` and leaves the registration in place. Passing no
settings at all is the only way to skip it.

**Why it must not have one.** A service worker pins a build inside the browser
and answers from it ahead of the network, which is the stale-copy problem above
wearing a different hat: the old build loads, pairs, and then cannot talk to
anything current. It buys nothing in exchange, because every conversation needs
the mailbox and none of it works offline.

**Removing one that already exists** is `web/boot.js`. Turning registration off
does nothing for a browser that registered one earlier, which will keep serving
its cached copy indefinitely, so any worker found is unregistered, its caches
are deleted, and the page reloads exactly once, guarded by `sessionStorage` so
it cannot loop.

That path is tested rather than assumed: serve a build whose worker caches,
visit it, deploy the current build to the same origin, reload, and confirm the
new build is running with no worker, no caches, and no second reload.

### The boot screen

CanvasKit plus the WebAssembly message layer is several seconds on a cold load,
and before `web/boot.js` existed those seconds were a blank white page on an
application that is otherwise near-black. The splash is markup and inline CSS in
`web/index.html`, so it paints immediately; the script that removes it is an
external file because `script-src 'self'` refuses inline code.

It comes down on `flutter-first-frame`, or on a `flutter-view` element
appearing, or after fifteen seconds regardless. The last one matters: a splash
that outlives a failed boot hides the error the user needs to see.
