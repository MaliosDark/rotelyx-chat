# Working on Rotelyx Chat

> **A security problem does not go in an issue.** Email <contact@ideoa.co.uk>.
> A public issue is a working exploit handed to everybody reading the
> repository, including whoever is running a mailbox at the time.
> [`SECURITY.md`](SECURITY.md) says what to include and what happens next.

## Sending code

Comment on your pull request with **"I have read CLA.md and I accept it."**,
once, for all of your contributions. [`CLA.md`](CLA.md) is short, and the reason
it exists is in its first paragraph: this client is AGPL-3.0-only and is also
the thing that goes into the stores, whose terms that licence cannot satisfy
alone, so the project has to be able to grant itself an exception and can only
do that over code it holds the rights to.

You keep your copyright and your name in the history, and your contribution
stays published under the AGPL like everything else.

If you would rather not, open an issue describing the change instead. An idea is
not a contribution in the copyright sense and there is nothing to sign for one.

## Building it

The engine is Rust and is not in this repository. Build it first:

```sh
tool/native/build-host.sh          # for tests and desktop
tool/native/build-android.sh       # for an APK
```

Then the usual:

```sh
flutter pub get
flutter run
```

[`docs/NATIVE.md`](docs/NATIVE.md) has the toolchain versions and what each
script actually does.

## Before you push

```sh
flutter analyze
LD_LIBRARY_PATH=build/native flutter test
```

Both, and both clean. The `LD_LIBRARY_PATH` is not optional: without it the
tests that touch the engine fail to load it and report as failures, which looks
like broken code and is a missing path.

## What the tests are for

Several of them read the source rather than exercise it, and they are named
after the defect they exist for:

- `a_call_has_somewhere_to_dial_test.dart`
- `the_screen_learns_about_the_loop_test.dart`
- `a_name_is_kept_and_never_demanded_test.dart`
- `no_store_rejecting_words_test.dart`
- `no_foreign_infrastructure_test.dart`

Each one is there because something failed silently and no ordinary test could
have caught it: a control that did nothing when pressed, a field that was blank
every time because the setting behind it was read and never written, a call
that reported a lost connection because the answer carried no address. Read the
comment at the top before changing one. If the property it holds has genuinely
moved, move the test with it rather than deleting it.

`no_foreign_infrastructure_test.dart` is the one to be most careful with. It
fails the build if this client gains a way to contact anything but the mailbox,
and every host it permits carries a written reason. Adding a host without one
is how "contacts no third party" stops being true quietly.

## House style

Comments say **why**, not what. The code already says what it does; what it
cannot say is which of the plausible alternatives were tried and why they were
wrong. Several files here are long because of that, and it is deliberate: the
next person to touch the audio path should not have to rediscover that two echo
cancellers in series remove the voice.

Numbers get their source. A constant with a value and no note is a constant
nobody can change with any confidence.
