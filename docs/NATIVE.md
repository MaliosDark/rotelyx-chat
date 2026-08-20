# Android and iOS

The client was web-only until this. Not by design: `rotelyx_wasm.dart` imported
`dart:js_interop`, `rotelyx_service.dart` imported that, and so the whole core
was a browser program. `flutter build apk` failed on the first import, and the
`android/` and `ios/` directories were scaffolding Flutter generates for every
project and nobody here had ever used.

## The shape of the fix

Four things were browser-specific and each is now a pair of files behind a
conditional import:

| Concern | Web | Everything else |
|---|---|---|
| The engine | `rotelyx-wasm` through `web/rotelyx_bridge.js` | `rotelyx-mobile` through `dart:ffi` |
| The socket | `package:web` `WebSocket` | `dart:io` `WebSocket` |
| Page hooks | URL strategy, the boot screen | nothing to do |
| Camera and file picker | `getUserMedia`, `<input type=file>` | not built, and says so |

```
lib/rotelyx/engine/
  api.dart        the contract, ordinary Dart, no platform anywhere in it
  backend.dart    one line: export native.dart if (js_interop) web.dart
  web.dart        the JS bridge
  native.dart     dart:ffi over librotelyx_mobile

lib/platform/
  socket.dart  socket_web.dart  socket_native.dart  socket_api.dart
  host.dart    host_web.dart    host_native.dart
  file_pick.dart  file_pick_web.dart  file_pick_native.dart  file_pick_api.dart
```

`rotelyx_wasm.dart` is now a facade over that, keeping the names the service
already used so the tested part did not have to move.

**There is one engine and two wrappers.** Neither contains protocol logic, and
if either ever does that is the defect: two implementations of a handshake
diverge, and the divergence presents as an interoperability bug while being a
security one. The protocol repository's `rotelyx-mobile` says the same thing
from the other side.

### The one rule that lives in two places

Tags rotate hourly, so the engine's addressing calls take the current hour since
the Unix epoch. The browser bridge computes it inside `web/rotelyx_bridge.js`, a
file copied verbatim from the protocol repository; `engine/native.dart` computes
it itself. Both are `now / 3_600_000`, and both are named in `engine/api.dart`.

Two devices on different platforms have to land on the same tag, so this is the
one number that must not drift.

## Building it

### Android

```bash
tool/native/build-android.sh          # release, stripped, all three ABIs
flutter build apk
```

The script puts `librotelyx_mobile.so` under `android/app/src/main/jniLibs/`,
one per ABI, and Gradle packages everything there without being asked. At
runtime `DynamicLibrary.open('librotelyx_mobile.so')` finds it because an
application's own `lib/<abi>` is on the loader path.

It builds **release by default**, which is the reverse of the usual convention
and is right here. A debug build of this crate is 300 MB per ABI: the crypto
stack drags in a great deal of generic code and debug keeps a symbol for all of
it. Nobody steps through this library from Dart, and the thing being debugged is
always on the other side of the ABI.

Requires the NDK. This machine has 23.1.7779620 under
`/home/serafin/Dinter/_devtools/android/sdk/ndk`, which works; anything newer
will too.

### iOS

```bash
tool/native/build-ios.sh              # must run on a Mac
```

Produces `ios/Frameworks/RotelyxEngine.xcframework`. Two manual steps in Xcode,
both of which the script prints:

1. Add it to the Runner target as **Do Not Embed**. It is a static library;
   embedding copies an archive into the bundle that nothing loads.
2. Add `-force_load` for it to Other Linker Flags. Every call goes through
   `dart:ffi` at runtime, so the linker sees no reference to any symbol and
   drops the lot. Without this the application builds, launches, and reports
   that the engine is not loaded, which reads as a packaging failure and is a
   linker one.

iOS uses `DynamicLibrary.process()` rather than opening a file, because the
engine is linked into the Runner binary rather than sitting beside it.

### This machine, for testing

```bash
tool/native/build-host.sh
LD_LIBRARY_PATH=build/native flutter test test/native_engine_test.dart
```

`engine/native.dart` is not Android code. It opens a shared library and speaks a
JSON ABI to it, and Linux can do both, so the wrapper a phone will run is the
wrapper those tests drive, here, with no handset.

What that leaves uncovered for Android is packaging: whether the `.so` reaches
the APK and whether the loader finds it. That is the only part of the native
path that needs a device to see, and it is a small one.

## What running it on a phone found

Three defects, none of which any test or any browser could have shown, because
each needed either the native path or a second real device.

**`INTERNET` was declared only in the debug manifest.** Flutter adds it there
for hot reload. A release build therefore had no network permission at all and
could not have opened a mailbox. The first attempt to pair would have failed
with a refused connection, on a device, after install.

**A deliberate close was reported as an error.** `platform/socket_*.dart`
emitted an event when the socket was closed on request. `_openMailbox` closes
the previous mailbox before opening a new one, the previous client's listener
was still attached, and so retrying a pairing failed the attempt that replaced
it. Fixed in two places: the socket no longer announces a close it was asked
for, and the service now detaches a mailbox's listeners when it replaces it.

**A conversation with no passphrase vanished the moment it was created.**
`store.save` returns at its first line when there is no key, and the
conversation list reads from the store, so a pairing that had just succeeded
left an empty screen. The unlock screen promises the application "forgets when
you close it"; it was forgetting immediately. `RotelyxStore` now holds
conversations in memory for the run when history is off, which is what that
sentence has always meant. `test/store_ephemeral_test.dart` pins it down,
including that nothing reaches disk.

**Messages arriving with the conversation closed were lost.** The conversation
screen was the only thing writing messages down, in its stream listener, so
anything that arrived while the user was elsewhere went to a broadcast stream
with no listener. Found by having a browser send to a phone that was still on
the pairing screen. `RotelyxService` records now, and the screen re-reads: a
widget is the wrong place to own durability, because a widget is allowed not to
exist.

## Verified on a device

A Note 58 on Android 16, arm64, against the production mailbox:

- The native engine loads. Settings reports `rotelyx/0.1.0` and a group ceiling
  of 1000, and those values can only come from `rotelyx_call` inside
  `librotelyx_mobile.so`.
- The phone hosts a meeting place and draws its QR.
- A browser joins that code and both reach a group of two at epoch 2, with a
  safety number each side computes independently.
- A message sent from the browser arrives, is decrypted, and is still there when
  the conversation is opened afterwards.

The QR was read out of a screenshot of the phone by `lib/qr/`, this project's
own decoder, which is also the first time that decoder has been pointed at a
photograph of a real device rather than a synthesised frame.

One side ran the WebAssembly build and the other the native library. Same crate,
two wrappers, and they interoperate.

## What is not built

**Calls.** This is the honest state of it, in two halves.

*The protocol repository has the hard half and it is tested.* `rotelyx-media`
does frame encryption, an adaptive jitter buffer and loss recovery;
`rotelyx-codec` is Telyx, a transform speech codec written for a channel where
latency is spendable. 150 tests pass. Fidelity mode loses nothing at 98 percent
packet loss, measured, and calls are relayed by construction:
`MediaOut::new` refuses every path policy that permits a direct route, so the
other party never learns your address and there is no switch to turn that off.

*Nothing connects it to a phone.* Three things are missing:

1. **A second entry point.** `rotelyx-mobile` is one JSON call, which is right
   for messaging and wrong for audio: a call moves fifty frames a second in each
   direction and cannot afford an encode per frame. It needs raw buffers with no
   allocation, and the protocol repository already says so.
2. **Device capture.** Nothing in either repository opens a microphone or a
   speaker. On Android that is `AudioRecord` and `AudioTrack`, on iOS it is
   AVAudioEngine, and both need a platform channel carrying PCM.
3. **A listening test.** Every codec figure recorded is objective, and codec
   quality is settled by ears. `bake_listening_test` and `scripts/listen` exist
   in the protocol repository and nobody has run them. Until somebody has, no
   comparison with Opus can be published.

**The camera, on a phone.** The QR decoder in `lib/qr/` is pure Dart and runs
anywhere; what it needs is frames. In a browser those come from `getUserMedia`
and a canvas. On Android that is CameraX and on iOS AVFoundation, both through a
platform channel delivering bytes. The scanner screen has always had a text
field under the viewfinder, so a meeting code can still be typed or read aloud.

**Attachments, on a phone.** A document picker is an intent on Android and a
view controller on iOS. `file_pick_native.dart` throws with an explanation
rather than opening nothing.

**Push.** `docs/PUSH.md` sets out three options and does not choose. That choice
has to be made before either store build.
