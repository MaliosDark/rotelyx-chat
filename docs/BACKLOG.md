# What is asked for, and where each piece stands

Written down because the list grew faster than it could be built and because a
list held in a conversation is a list that gets dropped. Everything here was
asked for directly. Nothing is here because it seemed like a good idea.

Status is one of **done**, **started**, **not started**, or **refused**, and a
refusal always says who refused it and why.

---

## Done

| | Where |
|---|---|
| Chat header no longer overflows on a phone | `ui/screens/chat.dart` |
| Conversations named after the other person, not "Conversation" | `rotelyx_service.dart`, `conversationName` |
| Reply to a message, swipe to start one | `rotelyx/quoted.dart`, `ui/screens/chat.dart` |
| Reply block drawn in this app's own shape language, no accent bar | `ui/screens/chat.dart` |
| Launcher icon is Rotelyx, not Flutter | `tool/brand/build.py`, `android/.../mipmap-*` |
| Launch screen is the Rotelyx mark on the app's own black, not a white flash | `android/.../launch_background.xml`, `values/styles.xml` |
| Store carries nickname, picture, pinned, muted, receipts, unread | `rotelyx/rotelyx_store.dart` |
| Control messages: read receipts, reactions, profile pictures on the wire | `rotelyx/signal.dart` |
| The burn shader and the widget that plays it | `shaders/burn.frag`, `ui/burn.dart` |
| Unread count in the conversation list, derived rather than counted | `rotelyx_store.dart`, `ui/screens/home.dart` |
| Tapping the conversation puts the keyboard away | `ui/screens/chat.dart` |
| The logo is centred, on every screen that shows it | `ui/brand.dart` |
| A passphrase generator, with the entropy stated in bits | `rotelyx/passphrase.dart` |
| Self-destructing messages, burning on both devices from one event | `rotelyx/burn_clock.dart`, `rotelyx/ephemeral.dart` |
| The conversation list updates when a message arrives, badge and all | `ui/screens/home.dart` |
| Notifications with the sender's name, picture and text, no third party | `rotelyx/alerts.dart`, `android/.../Notifications.kt` |
| Notification sound and vibration, generated rather than downloaded | `tool/sound/build.py` |
| Message text on a locked screen, as a switch | `ui/screens/settings.dart` |
| Receiving while the app is closed, without Firebase | `android/.../ConnectionService.kt` |
| Sixteen kilobyte page alignment, which Play requires | `tool/native/check-alignment.sh` |
| Release signing, target API 35, privacy manifest, export declaration | `docs/RELEASING.md` |
| The camera scans a meeting code on a phone | `android/.../QrCamera.kt`, `qr/camera_native.dart` |
| Renaming, pinning, muting and read receipts, per conversation | `ui/screens/contact.dart` |
| Profile pictures, cropped and stripped of metadata before they leave | `ui/screens/picture.dart` |
| A read tick that is never inferred | `ui/screens/chat.dart`, `rotelyx_service.dart` |
| Reactions, on a long press | `ui/screens/chat.dart` |
| Attachments on a phone, with no storage permission asked for | `android/.../FilePicker.kt` |
| A PIN for the application, stretched and rate limited | `rotelyx/lock.dart`, `ui/screens/pin.dart` |
| Swipe from the edge to go back, pull down for settings | `ui/gestures.dart` |
| The application lays out at a desktop width without overflowing | `ui/widgets.dart`, `test/widget_test.dart` |
| Desktop targets scaffolded, and the engine builds for them | `tool/native/build-desktop.sh` |

## Started, not finished

Audited against the code, not against what this list used to say. A field in the
store with no widget reading it is not "half done", it is a feature nobody can
use, and it is listed that way.

| | What is left |
|---|---|
| **Read receipts** | Built and switchable per conversation. What is left is the group case: the tick means "somebody read it" rather than "everybody did", and a group of eight deserves better than that |
| **Profile pictures** | Built. The picker is the system's document picker, so choosing one is two taps more than a gallery would be, and a gallery would cost the permission to read every image on the phone |

## Three bugs the new tests found, worth writing down

Each of these was invisible until something exercised the code, and each was
found by the work above rather than reported by anybody.

**Every button overflowed on a narrow screen.** `RxButton` put a `Text` inside a
`Row` with nothing allowing it to shrink, so a long label pushed past the
button's edge instead of ellipsizing. It had never been noticed because the
application had only ever been laid out on a phone that happened to be wide
enough. The widget test written when the desktop targets were scaffolded failed
at all three widths on its first run.

**The PIN could not be set at all.** `Lock.setPin` fed the PIN straight into the
engine's key derivation, which refuses a passphrase under eight characters, and
rightly so: that guard is about the secret protecting a conversation. So a six
digit PIN threw, the switch in Settings silently did not move, and nothing said
why. The fix is a domain-separated input, which also stops a PIN and a
passphrase that happen to match from deriving the same key.

**Re-locking on return never fired.** It watched for `AppLifecycleState.hidden`,
which reads better than the alternative and is not delivered on Android. The
PIN was set, the phone was left for forty seconds, and it came back to the same
screen without asking.

The first two were found by tests. The third was found by doing it on a device,
which is the only place it could have been.

## What is missing, in the order it hurts

### Calls

**The media path is built and proven.** `test/call_test.dart` opens a call on
two paired sessions, encodes a 440 Hz tone on one, hands the datagrams to the
other, and reads audio with real amplitude out the far end. It works only
because both are in the same MLS group: the key is derived from the group
secret, per sender, so a call is exactly as protected as a message.

What that took was a binding, not an implementation. `rotelyx-mobile` already
exported the six functions:

    rotelyx_call_open      a call on an established session
    rotelyx_call_capture   960 samples in, one datagram out
    rotelyx_call_deliver   a datagram that arrived
    rotelyx_call_playback  the next frame to play
    rotelyx_call_stats     participants, concealment
    rotelyx_call_close

`lib/rotelyx/engine/call_native.dart` is the Dart side. It is deliberately not
the JSON dispatcher the rest of the engine uses: fifty times a second in each
direction, wrapping 960 samples in a JSON envelope would cost more than the
codec it wraps. Buffers are allocated once per call and reused, because malloc
on the audio path is how a working call becomes an intermittent one on a slow
phone.

Two facts the tests pinned that are not obvious:

  * **The first frame of a call produces no datagram.** The encoder needs a
    forty millisecond window and is handed twenty at a time, so the first fills
    history. That is 20 ms of added latency and the price of the longer window.
  * **`playback` returns silence, not nothing.** A speaker is running whether or
    not the network is, and handing it nothing produces a click.

### What a call still needs

**Audio.** Nothing captures a microphone or drives a speaker. Android needs
`AudioRecord` and `AudioTrack` at 48 kHz mono, feeding and draining 960 sample
frames on their own thread, plus `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS`,
which are still deliberately absent from the manifest.

**Transport.** The datagrams have to reach the other device. The mailbox is
store and forward and wrong for this: a voice frame that arrives late is worse
than one that never arrives. `rotelyx-relay` exists in the protocol repository
for exactly this and nothing here speaks to it yet.

**Signalling.** Ringing, accepting, declining. This is the cheap part and the
pieces are already here: it goes over MLS as a `Signal`, the same way a read
receipt does, which means the invitation to a call is as protected as the call.

**A screen.** Nothing to show, answer or hang up with.

### Desktop

Scaffolded on 19 August 2026, and the native engine builds for it:
`tool/native/build-desktop.sh` produces a 3.3 MB `librotelyx_mobile.so` and the
engine tests pass against it.

What is missing is a toolchain on this machine rather than code: a Linux build
needs `ninja-build`, `clang`, `libgtk-3-dev` and `pkg-config`, none of which are
installed here and none of which is something to install on somebody's machine
uninvited. Windows needs Visual Studio's C++ workload; macOS needs Xcode.

The window has also never been laid out for a large screen beyond what the
existing breakpoint does, and a desktop messenger with a phone's proportions
looks like a phone emulator.

### iOS, the last mile

The extension target, the App Group and the entitlements are built. What is left
is the decision in `docs/PUSH.md` about putting the vault key in the Keychain,
without which the extension can show who a message is from and not what it says,
and four steps that need a Mac and a developer account.

### Smaller, and honest about being smaller

Editing a message, deleting for everybody, forwarding, copying, marking unread,
exporting a conversation, and biometric unlock. None started. Search is built.

## How a message burns on both devices

Worth writing down because the obvious implementation is wrong in a way that is
invisible until somebody trusts it.

A timer means "gone this long after you have read it". That sentence has one
starting point, and the naive build gives it two: the sender's copy starts when
they press send, the recipient's when they open it. The two then count down from
different moments, and the sender watches theirs burn with no idea whether the
other one was ever opened. Starting on arrival is worse: a message that begins
expiring inside a mailbox can be destroyed by anybody who keeps its recipient
offline.

So both clocks start on the same event, the recipient's reading:

1. The sender wraps the body with a duration and sixteen random hexadecimal
   characters, in `ephemeral.dart`. The identifier is in the body, so both
   copies inherit the same value. A timestamp could not serve: each device
   stamps a message with its own clock, so the two copies of one sentence
   disagree about when it happened.
2. Their copy has no deadline. The bubble shows an unlit flame and a dash,
   because "how long is left" has no answer yet and a number would be a guess.
3. The recipient opens the conversation. `onRead` in `burn_clock.dart` sets a
   deadline on everything they were sent, and hands back the identifiers.
4. Those go out as one `Signal.burnRead` envelope, through MLS like any
   sentence. Queued in the conversation first, so a read that happens offline
   is delivered on the next join rather than lost.
5. The sender receives it and `onAcknowledged` starts their clock.

The two clocks are not synchronised and are not meant to be. The sender's runs
behind by however long the acknowledgement took, because making them agree would
need a shared clock, which is the thing this design refuses to depend on.

Measured on a phone paired with a browser: the browser sent a thirty second
message and its copy sat with no deadline through fifteen seconds of polling.
The phone opened the conversation, and the browser's copy went to twenty six
seconds and counted down while the phone burned its own at zero.

The acknowledgement is sent whatever the conversation's receipt setting says,
and that is stated in `signal.dart` rather than left quiet: a self-destructing
message cannot destroy itself on both devices unless one of them says "seen".
What it discloses is bounded. It names only messages that were already going to
announce their own reading by vanishing, and unlike an ordinary read receipt it
is not a high-water mark, so it says nothing about anything else in the
conversation.

## Not started

### Locking one conversation, which is the half that is left

The **application** PIN is built: `rotelyx/lock.dart` and `ui/screens/pin.dart`.
It is stretched through the same derivation the vault uses for a passphrase,
counts failures across restarts, and stops answering for five minutes after ten
wrong tries.

The interface says what it is, because a lock that implies more than it delivers
is worse than no lock: it hides the interface from somebody who picked up the
phone, and it does nothing against somebody who took the storage away.

**A conversation lock is the one still worth building**, and it is a different
thing rather than the same thing applied twice. It has to seal that
conversation's log under a key derived from the passphrase *and* the PIN, so a
locked conversation is genuinely unreadable rather than merely not drawn.
Getting that wrong does not produce a weak lock, it produces a curtain with a
padlock painted on it, which teaches people to trust it for things it cannot do.

The distinction is written at the top of `rotelyx/lock.dart` so that whoever
builds the second half does not have to rediscover it.

- **Group read receipts.** The tick means somebody read it, not everybody. A
  group of eight deserves better than that
- **Editing a message, deleting for everybody, forwarding, copying, marking
  unread, exporting a conversation, biometric unlock.** None started. Search is
  built
- **iOS attachments and camera.** Both are built for Android through a platform
  channel and neither is wired on iOS
