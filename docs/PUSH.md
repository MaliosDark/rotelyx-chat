# Notifications, and waking a device that is not running

Two different problems that get given one name.

**Telling somebody a message arrived** is done, on Android and in the browser,
by this application itself. No push service is involved. See "What is built"
below.

**Waking a device that is not running at all** is the hard one, it is what
"push" usually means, and the obvious implementation quietly undoes a property
the rest of the system is built to provide. That is the rest of this note.

## What the platforms actually require

| | Required | Firebase needed? |
|---|---|---|
| iOS | APNs | **No** |
| Android (Play) | FCM in practice | Yes |
| Android (F-Droid) | UnifiedPush | No |
| Android (no Google) | Foreground socket | No |

**On iOS, Firebase buys nothing.** A server can talk to APNs directly with a JWT
signed by a `.p8` key. `firebase_messaging` is a wrapper around that, and using
it puts Google in the path of a notification Apple was going to carry anyway.

On Android FCM is the pragmatic default for Play Store distribution.
[UnifiedPush](https://unifiedpush.org) is the open alternative Element ships; it
works against a self-hosted server and costs the user installing a distributor
app. Molly, the de-Googled Signal fork, keeps a foreground socket instead and
pays for it in battery.

The sensible split is FCM in the Play build, UnifiedPush in the F-Droid build,
and the app saying which one is in use.

## The part that is not about platforms

`docs/THREAT-MODEL.md` ADV-9 covers what Apple and Google learn: that a device
was woken, and when. Content-free pushes handle the rest, and that analysis is
right.

It does not cover what happens one step earlier.

**To push to a device, the mailbox needs its device token.** A device token is
stable for months. A mailbox tag rotates every hour, specifically so that two
tags from the same member are unlinkable without the group key.

Store `token → tag` and the mailbox operator can follow the token across every
rotation and re-link the whole sequence. The tags still look unlinkable on the
wire; the table beside them says otherwise. The adversary here is not Apple or
Google, it is **ADV-4, the mailbox operator, which is you**.

This is the same shape as the free-tier metering bug in
`rotelyx-mailbox-server::access`: the cryptography is sound and an identifier
added for an operational reason re-links what the cryptography separated.

## One token per tag does not work, although it reads as though it should

The batch scheme above is the right shape for a transport that can mint tokens.
**APNs cannot.** A device has one token and it is the same string in every row.
Registering it against a hundred tags produces a hundred rows that all name the
same device, which links those tags together exactly as before.

This is written down rather than quietly dropped, because it survives a review
and fails at implementation, which is the worst order to find out.

## What actually removes the linkage

**Stop binding the wake to arrival.**

The mailbox wakes every registered device on a fixed schedule, whether or not
anything arrived for it. The device wakes, collects from its own tags, and shows
a notification only if there was something.

The mailbox then holds a token with no tag beside it. There is nothing to link,
by construction rather than by policy. Apple sees a heartbeat identical for
every user, carrying no information about who was messaged or when.

This is better than what Signal does. Signal pushes on arrival, which hands
Apple the timing of every conversation, and says so honestly. This does not have
to.

| | Wake on arrival | Wake on schedule |
|---|---|---|
| Mailbox knows token to tag | **Yes** | No |
| Apple learns when a message arrived | **Yes** | No |
| Latency | Immediate | Up to the interval |
| Battery | One wake per message | One wake per interval |

The costs are real and are the user's to weigh, so the interval is stated in
Settings rather than buried. Five minutes is the proposed default.

### The delivery detail that decides the interval

Apple throttles silent pushes: `content-available` with no alert is best-effort
and may be delayed or dropped. A push carrying an alert is not throttled.

So every wake carries an alert, and the notification service extension decides
what to do with it: show the decrypted message, or hand back empty content,
which suppresses it. A wake that finds nothing shows nothing and the user never
learns it happened. The `decoy` flag in the payload is what marks those.

## The contract, which both sides now implement

Built on both sides. The server is `crates/rotelyx-mailbox-server/src/wake.rs`
in the protocol repository, and this is the surface between them.

**Client to mailbox**, over the existing socket:

    {"op": "registerWake", "token": "<hex>", "kind": "apns", "secret": "<hex>"}
    {"op": "revokeWake",   "secret": "<hex>"}

The secret is what makes a token an address rather than a credential.

The first version of this took a token on `revokeWake` and nothing else, so
anybody who learned a token could take that phone off the schedule. Nothing was
disclosed by it and it required already knowing a token, so it is a silencing
rather than a leak. It is still the worse failure of the two: somebody whose
notifications were switched off by a stranger goes on believing they are on.

Sixty four hexadecimal characters, made once on the device and kept there,
outside the vault because notifications are switched on and off while the
application is locked. The mailbox stores only its SHA-256, so a stolen registry
file yields the power to be woken and not the power to silence. `revokeWake`
does not carry the token at all, which is one fewer place a device token
travels.

The reply is the same whether or not anything was removed. Distinguishing them
would turn the frame into an oracle for testing guessed secrets.

**Mailbox to client**:

    {"op": "wakeRegistered", "everySeconds": 300}

The mailbox stores the token, the kind, and nothing else. No tag, no account,
no address. It then wakes every stored token every `everySeconds`.

**Mailbox to Apple**, per wake:

    POST https://api.push.apple.com/3/device/<token>
    authorization: bearer <JWT, ES256, signed with the .p8 key>
    apns-topic: com.rotelyx.ios
    apns-push-type: alert
    apns-priority: 10

    {"aps": {"alert": {"title": "Rotelyx"}, "mutable-content": 1},
     "decoy": true}

`mutable-content: 1` is what lets the extension replace it. The JWT is signed
with an APNs authentication key created in the Apple Developer account, is valid
for an hour, and must be reused rather than minted per push or Apple rate-limits
the token endpoint.

The mailbox stores a `Device { token, kind }` in a `BTreeSet`, ordered so a
snapshot of the same contents is byte-identical: a file whose bytes change when
its contents do not is a file whose modification time says somebody reconnected.
It is sealed under the same passphrase as the mailbox, because a list of push
tokens is the closest thing that server holds to a list of its users.

A device Apple reports as gone, with a 410, is forgotten rather than called
forever.

Started with:

    rotelyx-mailbox-server \
      --apns-key /etc/rotelyx/AuthKey_XXXXXXXXXX.p8 \
      --apns-key-id XXXXXXXXXX \
      --apns-team-id YYYYYYYYYY \
      --apns-topic com.rotelyx.ios \
      --wake-every 300 \
      --wake-state /var/lib/rotelyx/wake.sealed \
      --mailbox-state /var/lib/rotelyx/mailbox.sealed

All three APNs flags together or none. A key without a team id produces a token
Apple rejects with `InvalidProviderToken`, and finding that out from a phone
that quietly stopped receiving is far worse than finding it out at startup, so
a partial configuration refuses to start.

Without the flags the server wakes nobody and **says so** when a device asks,
rather than accepting a registration it will never act on.

## What is built, on the client

  * `AppDelegate.swift` asks the user, registers with Apple, and hands the token
    to Dart. No SDK, no configuration file, nothing fetched at launch.
  * `lib/platform/apple_push_native.dart` is the wire to it.
  * `lib/rotelyx/push.dart` declares `ApnsPush`, and Android deliberately
    declares `NoPush`, because Android holds its own connection instead.
  * `lib/rotelyx/mailbox_client.dart` sends `registerWake` and `revokeWake`.
  * `ios/NotificationService/` is the extension, with the decoy path built and
    the decryption left, which needs the Rust library and an App Group
    container shared with the application.
  * `test/push_test.dart` asserts the absence: a grant names a device and
    nothing about its conversations.

## What is built, on the mailbox

`crates/rotelyx-mailbox-server/src/wake.rs`, with six unit tests and five
protocol tests against the real server. The ones worth naming:

  * `what_is_stored_says_nothing_about_conversations` subscribes to a tag and
    registers a token **on the same connection**, which is the situation an
    operator could exploit if the two were recorded together, and then asserts
    that the stored row has two fields and no tag.
  * `a_server_that_cannot_wake_says_so` pins the refusal. A device told it is
    registered by a server that will never call Apple is a phone that silently
    stops receiving.
  * `an_unknown_kind_is_refused` pins `fcm` being rejected.
  * `a_token_that_is_not_one_is_refused` covers a slash, which would address a
    different path on Apple's server, and a newline, which would split the
    request.

## The Xcode project, edited from a script

There is no Xcode on the machine this was built on, so the target was added by
editing `project.pbxproj` directly and then checking the result:

    python3 tool/ios/check-project.py

    targets:  RunnerTests, Runner, NotificationService
    objects:  77

A broken project file does not fail loudly. Xcode refuses to open it, or opens
it with a target silently missing, and the first sign is a build on somebody
else's machine. So the checker reads it back: braces and parentheses balance,
every identifier that is referenced is defined, every section comment appears
once, every target has a configuration list and a product, the extension is
embedded, and the entitlement files the settings name exist on disk.

Two dangling references are excused by name rather than hidden. Three
`Pods-*.xcconfig` references resolve only after `pod install`, which runs on
macOS. One, a Frameworks phase named by `RunnerTests`, has never been defined; it is
harmless because that target has no frameworks, and it is left alone so the
check reports what it finds rather than what it tidied.

**This is not a substitute for opening it in Xcode.** It is the difference
between finding a mistake here and finding it there.

### What the edit added

  * A `NotificationService` target, product type `app-extension`, with Sources,
    Frameworks and Resources phases and Debug, Release and Profile
    configurations.
  * An **Embed Foundation Extensions** copy phase on Runner, and a dependency,
    so the extension is built before the app and carried inside it. Without the
    embed phase the extension builds and is left on the floor.
  * `Runner/Runner.entitlements` and
    `NotificationService/NotificationService.entitlements`, wired into all
    three Runner configurations and all three extension ones.
  * `PrivacyInfo.xcprivacy` in Runner's Resources, which was written earlier
    and was not in the bundle. A privacy manifest on disk and not in the target
    is a manifest the App Store does not see, and the rejection does not say so.
  * `SharedContainer.swift`, in Runner's Sources.

### The App Group

`group.com.rotelyx.ios`, named in both entitlement files and once in
`SharedContainer.swift`, because three literals is two too many.

The conversation log now lives in it. `lib/main.dart` builds `GetStorage` with
the container path rather than calling `GetStorage.init()`, which takes a name
and no path. The order matters: `GetStorage` caches by container name, so
constructing it with the path first is what makes every later `GetStorage()`
elsewhere hand back the same instance. Doing it the other way round yields a
cached instance pointing at the wrong directory, and the symptom is history that
silently stops being shared.

Null container, on a build whose provisioning profile does not carry the App
Group, falls back to the application's own directory. History still works and
only the extension loses its view of it, which is the right way round.

## The decision left, which is not mine to take quietly

**The extension cannot yet read anything, and the reason is the vault key.**

The log in the shared container is sealed. The key is derived from the
passphrase and held in memory only while the application is unlocked. An
extension woken on a locked screen has no memory to read it from and nobody to
ask for a passphrase.

The only mechanism that works is the iOS Keychain with
`kSecAttrAccessibleAfterFirstUnlock`, shared through the keychain access group
the entitlements already declare. That is how Signal does it.

It is a real change to the threat model, so it is written here rather than
implemented quietly:

| | Today | With the key in the Keychain |
|---|---|---|
| Phone off, seized | Nothing. The key exists only in a head | Nothing |
| Phone on, never unlocked since boot | Nothing | Nothing |
| Phone on, unlocked once, then locked and seized | Nothing | **The key, to anyone who defeats the Keychain** |
| iOS notification can show the message | No | Yes |

The third row is the whole trade. Hardware protection is real and defeating it
is not casual, but "the key is not on the device" and "the key is on the device
behind the Secure Enclave" are different sentences and only one of them is true
afterwards.

Until that is decided, the extension suppresses decoys and shows "New message",
which is exactly what a locked screen with previews switched off shows anyway.

## What still needs a Mac

1. Open `ios/Runner.xcworkspace` once and confirm the three targets are there.
2. Enable the **Push Notifications** capability on Runner. The entitlement is
   written; the capability has to be switched on in the developer account so the
   provisioning profile carries it.
3. Register the App Group `group.com.rotelyx.ios` in the developer account
   and confirm both targets' profiles carry it.
4. Create an APNs authentication key and put the `.p8` on the mailbox server,
   never in this repository.
5. If the Keychain decision above is taken: link `librotelyx_mobile` into the
   extension target, and take a lock in the shared container around the receive
   path. Two processes stepping the same MLS ratchet lose messages permanently,
   and iOS can run the extension while the application is in the foreground.

## What is built

### Android: this application notifies itself

`lib/rotelyx/alerts.dart` decides, `lib/platform/notify_native.dart` carries it
across, and `android/.../Notifications.kt` posts it. The message is decrypted on
this device before anything is shown, because this application holds the mailbox
socket itself. Nothing is registered with Google and nothing leaves.

It shows the sender's name and their picture through `MessagingStyle`, the text
of the message, and whether that text may appear on a locked screen is a switch
in Settings rather than a decision made for the user. Sound and vibration come
from a notification channel, and the sound is generated by `tool/sound/build.py`
rather than downloaded, so there is no licence to honour and no provenance to
take on faith.

### Android: the foreground service, and the measurement that forced it

Notifying from inside the application does not work on its own, and not because
the notification code is wrong.

Measured on a device: the application was paired, sent to the background, and
the screen switched off. A message was deposited. The screen came back on and
the conversation still read "No messages yet". The envelope had been sitting in
the mailbox the whole time and nothing collected it, because Android had frozen
the process holding the socket. That is the platform working as designed, and it
is the entire reason Firebase exists.

`ConnectionService.kt` is the exemption. It holds no socket and knows nothing
about messages; its only job is to be a reason for the system not to freeze the
process the Dart isolate is running in. It costs a permanent notification and
battery, so it is off by default and switchable, and the notice it shows says
what it is for rather than "Rotelyx is running".

Declared `specialUse`, not `dataSync`, because Android 15 caps a data sync
service at six hours in any twenty four, which for a messenger means it stops
working every evening. `specialUse` is reviewed by a human at Play. See
`docs/RELEASING.md`.

### The browser

`lib/platform/notify_web.dart` uses the Notification API, which is part of the
browser and reaches nothing. The Push API is deliberately not used: it needs an
endpoint, which for Chrome is Google's and for Firefox is Mozilla's, and it
would tell that service exactly what Firebase would. A tab that is closed is not
running, and that is stated rather than papered over.

### iOS: nothing, and why

iOS does not permit a persistent background socket for a messenger. There is no
equivalent of the foreground service, so the Android mechanism cannot be ported.
An iOS build receives messages when it is opened.

Closing that needs the push path below. It is a real piece of work and it is the
one place where this design has to pay a third party something.

## What iOS would take

1. **The mailbox sends the push, not the app.** The mailbox is yours. It already
   knows an envelope landed on a tag. It signs a JWT with a `.p8` key and calls
   APNs directly. Firebase is not needed on iOS and adds Google to a path Apple
   was going to carry anyway.
2. **The push carries no content, or carries the sealed envelope.** APNs allows
   four kilobytes. An envelope that fits can travel inside the push and be
   decrypted by the extension with no network round trip at all, which is fewer
   moving parts than fetching after waking.
3. **A Notification Service Extension**, a second Xcode target, receives it,
   decrypts on the device, and rewrites the notification with the real sender
   and text before it is shown.
4. **The registration problem above still applies**, and it is the part that
   matters. One token per tag, burned on use, is the shape that keeps it from
   re-linking the rotations.
5. **Decoy wakes.** The push node also wakes devices on a schedule, whether or
   not anything arrived. Apple then sees a rhythm that is the same for every
   user and carries no information about who was messaged. This is the piece
   that beats what Signal does rather than matching it, and it costs battery
   in exchange for the timing oracle.

`PushKit` is worth using for the voice call path, where Apple permits it and it
is the only way a call rings on a locked phone. Using it for messages gets the
entitlement revoked.

## Delivery state, which needs none of this

The mailbox answers `stored` for a deposit, so the app can honestly say **in
their mailbox**, and stops there. A group message is one deposit per recipient
and therefore one `stored` each: the request that named every recipient at once
was removed, because it handed the operator the whole membership in one frame.

Not "delivered", not "read", except for one narrow case that has to be an
exception: a self-destructing message acknowledges its own reading, because
otherwise the two copies cannot burn from the same moment. That acknowledgement
names only messages that were already going to announce their reading by
vanishing. See `lib/rotelyx/burn_clock.dart`.
