# Shipping this to the two stores

Everything both stores check, what this repository already satisfies, and what
is left. Written because most of it fails at upload rather than at review, and
an upload that fails at midnight before a launch is a bad time to read a policy
page for the first time.

Verify the mechanical parts with:

    tool/native/check-alignment.sh
    flutter analyze lib && flutter test
    flutter build appbundle --release

---

# Google Play

## Already done in this repository

| | Where |
|---|---|
| Target API 36, compile against 36 | `android/app/build.gradle` |
| Sixteen kilobyte page alignment on all three ABIs | `tool/native/build-android.sh` |
| A signing config that reads a key outside the repository | `android/app/build.gradle` |
| Signing material excluded from version control | `.gitignore` |
| Foreground service type declared, with its justification | `AndroidManifest.xml` |
| `POST_NOTIFICATIONS` declared and requested at runtime | `Notifications.kt`, `MainActivity.kt` |
| Uncompressed native libraries | `packagingOptions`, `useLegacyPackaging false` |

## Target API 36

Play has required API 35 as a floor for new applications and for updates since
31 August 2025. This targets and compiles against **36**, which is above the
floor. Compiling against a level and targeting it are two settings and both are
needed: targeting an older API with a newer compile SDK is accepted by Gradle
and rejected by Play.

## Sixteen kilobyte pages

Android has always used four kilobyte memory pages. Devices from Android 15
onward may use sixteen, and a shared library whose `LOAD` segments are aligned
to four **will not load at all**: `dlopen` fails and the process dies with the
application already on screen. From 1 November 2025 Play rejects the upload
rather than letting the crash reach users.

This matters here because this application ships a Rust library. It was aligned
to `0x1000` and is now aligned to `0x4000`, through a linker flag rather than an
NDK upgrade, so it does not depend on which toolchain a given machine has:

    -Wl,-z,max-page-size=16384

`tool/native/check-alignment.sh` reads the alignment back out of the built
libraries. A flag that is silently ignored looks exactly like a flag that
worked, so the check reads the artefact rather than trusting the build.

## Signing

`flutter create` leaves the release build signed with the debug key. Play
rejects that, and it deserves to: the debug key is identical on every machine
that has ever run Android Studio, so anything signed with it can be replaced by
anybody.

Create the upload key once:

    keytool -genkey -v -keystore ~/rotelyx-upload.jks \
      -keyalg RSA -keysize 4096 -validity 10000 -alias upload

Then `android/key.properties`, which `.gitignore` excludes:

    storePassword=...
    keyPassword=...
    keyAlias=upload
    storeFile=/home/you/rotelyx-upload.jks

The build prints a warning and falls back to the debug key when that file is
absent, so `flutter run --release` still works on a machine without it and
nobody uploads an unsigned build by accident.

Enrol in Play App Signing. Play then holds the app signing key and the upload
key only proves an upload came from you, which means losing it is a support
ticket rather than the end of the application.

## Build the release obfuscated, and know what that does not cover

    flutter build appbundle --release \
      --obfuscate --split-debug-info=build/symbols

`--obfuscate` renames Dart symbols. `--split-debug-info` writes the mapping to a
directory instead of into the binary, and **that directory has to be kept**: it
is the only way to read a crash report from a released build afterwards. It is
excluded from the repository along with the rest of `build/`, so keep it beside
the upload key.

### What is in a release binary that nobody puts there on purpose

Measured on a finished APK rather than assumed:

| | Before | After |
|---|---|---|
| Strings naming the build machine's user | **259** | 1 |

The 258 came from the Rust library. `rustc` records the absolute path of every
source file it compiles, for panic messages, and those survive stripping. The
finished library spelled out the build user's home directory, their cargo
registry and where the protocol repository lives.

`tool/native/build-android.sh` and `tool/native/build-desktop.sh` now pass
`--remap-path-prefix`, the same mechanism the reproducible-builds work uses, so
those paths come out as `/cargo/registry/...`. A panic still names the crate and
the line, which is everything a backtrace is for.

**The one that is left** is the project's own directory, written into the Dart
snapshot as the source URI of the generated plugin registrant. It follows the
folder the repository sits in, and neither obfuscation nor a symlinked build
path removes it: the tool resolves to the real directory. The only fix is to
name that folder something you are content to ship.

## Upload an App Bundle, not an APK

    flutter build appbundle --release

Play has not accepted APKs for new applications since August 2021. The APK
builds in this repository are for installing on a device during development.

## The foreground service, which a human reads

The connection service is declared `specialUse`, and `specialUse` is reviewed by
a person at Play. The justification is in `AndroidManifest.xml` as
`PROPERTY_SPECIAL_USE_FGS_SUBTYPE` and has to be repeated in the Play Console
under **App content, Foreground service permissions**, along with a screen
recording showing the feature working.

The claim is true and short enough to check: this application maintains its own
end to end encrypted connection to its mailbox so that no third-party push
service learns when a user receives a message. There is no account to wake and
no push token to register. It is off by default and switchable in Settings.

`dataSync` would not need the justification and is capped at six hours in any
twenty four on Android 15, which for a messenger means it stops working every
evening. That is why this takes the reviewed path instead of the quiet one.

## Data safety

Declared in the console, not in the manifest, and it must match what the
application does. Everything here is "no data collected":

| Question | Answer |
|---|---|
| Does your app collect or share any user data? | No |
| Is data encrypted in transit? | Yes, end to end |
| Can users request deletion? | Nothing is held to delete |

Play cross-checks this against the permissions and against network traffic seen
during automated review. The permission list is `INTERNET`,
`POST_NOTIFICATIONS`, `VIBRATE` and the foreground service permissions, and the
only host contacted is the mailbox. Both hold up.

A privacy policy URL is required whatever the answers are, and it must be
reachable from a browser with no login.

## Other console requirements

  * Content rating questionnaire. A messenger with user-to-user communication
    rates higher than it feels like it should, and answering otherwise is the
    kind of thing that gets an application pulled later.
  * Target audience and children's policy. Declare it is not for children, or
    the whole Families policy applies.
  * Ads declaration: none.
  * Store listing: title, short and full description, an icon at 512 by 512, a
    feature graphic at 1024 by 500, and at least two phone screenshots.
    `docs/screens/` has device captures.
  * Account deletion URL. Required even for an application with no accounts,
    where the honest answer is a page saying there is nothing to delete because
    there was never an account.

---

# The App Store

## Already done in this repository

| | Where |
|---|---|
| Privacy manifest with required-reason APIs | `ios/Runner/PrivacyInfo.xcprivacy` |
| Export compliance declared honestly | `ios/Runner/Info.plist` |

## The privacy manifest

Required since May 2024. An upload without one, or one that omits an API the
binary calls, is rejected before review with `ITMS-91053`.

`PrivacyInfo.xcprivacy` is written and declares the three categories this
application's storage touches: file timestamps `C617.1`, `UserDefaults`
`CA92.1`, and free disk space `E174.1`. Tracking is false and collected data
types are empty, which is true rather than optimistic: there is no analytics,
no crash reporter, no advertising identifier and no account.

It is now in Runner's Copy Bundle Resources phase, added by the same script that
added the extension target. A file that exists on disk and is not in the target
is not in the app, and the rejection message does not say so. Verify with:

    python3 tool/ios/check-project.py

## Export compliance, which this application cannot skip

`ITSAppUsesNonExemptEncryption` is set to **true**.

The exemption most applications claim covers software that only calls the
encryption already in the operating system. This one does not: it ships its own
MLS and X-Wing implementation in a Rust library, which is exactly what the
exemption excludes. Declaring false to skip the questionnaire is a false
statement to Apple and, through them, to the United States Bureau of Industry
and Security.

What it requires is lighter than it sounds, because **nothing here is
invented**: MLS is RFC 9420, X25519 is RFC 7748, ML-KEM-768 is FIPS 203, X-Wing
is a published IETF draft. The EAR's "non-standard cryptography" means
proprietary or unpublished functionality, and none of this is either. That was
already the right engineering decision; it is also the difference between a form
and a licence application.

Which form depends on one question: **is the protocol source published?**

  * Published as open source: since a March 2021 rule change, the email
    notification to BIS is required only for non-standard cryptography. This is
    close to the lightest case there is.
  * Not published: mass-market software self-classified under License Exception
    ENC 740.17(b)(1), which is a report rather than an application, plus an
    annual self-classification report to BIS due 1 February.

Either way there is no licence that can be refused.

France separately requires a declaration to ANSSI, under a decree that treats
even ordinary TLS as a means of cryptology. Since 2024 it is filed through App
Store Connect rather than sent to ANSSI directly. Nobody is refused; people are
surprised.

`docs/JURISDICTIONS.md` has the full picture, including the countries where this
cannot be listed at all and the ones whose law would require changing what it
is.

None of this is legal advice.

## Notifications on iOS

iOS does not permit a persistent background socket for a messenger, so the
Android mechanism cannot be ported. The client side of the replacement is built:
registration with Apple in `AppDelegate.swift`, the transport in
`lib/rotelyx/push.dart`, the mailbox frames in `mailbox_client.dart`, and the
notification service extension in `ios/NotificationService/`.

**No Firebase.** Firebase cannot deliver to an iPhone; it relays to APNs. Using
it would mean Apple sees the push and Google sees it too, and it would put the
Firebase SDK in the binary, which registers an instance identifier with Google
at launch and turns the App Privacy answer from "Data Not Collected" into a
list. The mailbox calls Apple directly with a JWT signed by a `.p8` key.

What remains is the mailbox side and five Xcode steps, both listed in
`docs/PUSH.md`. A Notification Service Extension target cannot be created from a
script.

## Other requirements

  * A paid Apple Developer Program membership, and the App Store Connect record
    created before the first upload.
  * A privacy policy URL and App Privacy answers, which for this application are
    "Data Not Collected" across the board.
  * Minimum deployment target. Flutter's floor moves; whatever it is must match
    `ios/Podfile` and the Xcode setting or the archive fails at link time.
  * Screenshots for every device size the listing claims, at the exact pixel
    dimensions App Store Connect asks for.
  * Review notes. Without them review stalls at a screen with a QR code and
    nobody on the other side of it, which is guideline 2.1 and the largest
    single category of rejection there is. Two things answer it, and they answer
    different halves:

    **A note to self** makes the application usable on one device with nothing
    arranged. It is a real conversation, sealed and delivered through the
    mailbox like any other, so a reviewer can compose, send, watch a message
    burn, and try the settings. What it cannot do is show them that delivery
    between two people works, because from the outside it is indistinguishable
    from a local notepad.

    **`tool/review_peer.dart`** answers that half. It is a second party,
    somewhere else, that replies. Mint a phrase for the submission, run

    ```
    LD_LIBRARY_PATH=build/native dart run tool/review_peer.dart "<phrase>"
    ```

    and put in the review notes: open the app, choose **New conversation**, the
    **On a call** tab, type that phrase, and send anything. A reply comes back.

    Check it answers before submitting, with the same phrase in another
    terminal:

    ```
    LD_LIBRARY_PATH=build/native dart run tool/review_peer_check.dart "<phrase>"
    ```

    The phrase is a door, and anybody who reads the review notes can walk
    through it. Use one minted for a single submission, run the peer for that
    window, and stop it when review is done.

## Three Android traps, each found by looking rather than by a build failing

**Target API level has a date on it.** Google Play stopped accepting new
applications and updates targeting below Android 16 on **31 August 2026**, and
an extension can be requested until 1 November. `compileSdkVersion` and
`targetSdkVersion` are 36. The build is clean and the application has been run
on a device at API 36: edge-to-edge, which Android 16 stops making optional,
lands correctly because every screen already sits inside a `SafeArea`.

**A dependency's native library counts too.** `check-alignment.sh` used to read
`android/app/src/main/jniLibs`, which holds only what this project builds, and
it passed while the package was not shippable: CameraX 1.3.4 shipped
`libimage_processing_util_jni.so` aligned to four kilobytes. Play looks at the
upload, so the script now does the same, and CameraX is pinned at 1.4.2 where
that library is aligned to sixteen.

**An architecture can arrive without an engine.** The package carried an `x86`
folder holding CameraX and nothing else, no `libflutter.so` and no
`librotelyx_mobile.so`, because a dependency built for an architecture Flutter
dropped years ago. A device that picked that folder would install an
application whose engine is not inside it. `abiFilters` now pins the three that
are real.

Run this before every upload, against the artifact and not the source tree:

```
flutter build apk --release
tool/native/check-alignment.sh
```

---

# What is still open

| | |
|---|---|
| iOS notifications | Needs the mailbox to send a push and an extension to receive it. `docs/PUSH.md` |
| The Play foreground service declaration | Console form and a screen recording, once there is a console |
| An upload key | `android/key.properties` is absent, so a release build signs with the debug key and Play refuses it. Generated once, by whoever owns the account: a lost upload key means going through Google support to publish again |
| Export self-classification | A report to BIS, before the first iOS distribution |
| `PrivacyInfo.xcprivacy` in the Xcode target | One drag, in Xcode, once |
