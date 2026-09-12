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

## One rule that is not obvious from the code

**One mailbox connection asks about one conversation.** If you need the
application to listen on more than one conversation, open more than one
connection. Never add a second conversation's addresses to a socket that is
already listening for another.

The reason is not in the code you will be editing, which is why it is here. The
mailbox holds every address and that is fine, because addresses rotate and one
on its own names nobody. What it must never be handed is which addresses go
together: a connection subscribed to two conversations has told the mailbox
those conversations belong to one device, and that is the first thing the
threat model promises the mailbox cannot learn. Every page on the website and
the privacy policy make that promise in Ideoa Labs' name.

It has been done twice, both times for a good reason (a call in a group nobody
had open; messages arriving in conversations not on screen), both times every
test passed, and both times it came out. `SocketOwnership` in
`rotelyx_service.dart` is the object every subscription now goes through, it
refuses a second conversation, and
`test/one_connection_never_asks_about_two_conversations_test.dart` checks it
and counts the call sites. If that test fails on your change, the change is
the problem, not the test.

The cost of the rule is connections, and the mailbox's nginx allows ten per
address (the server, sixteen). So six of the most recently active
conversations hold a socket each, and two sockets take turns through all the
others, ten seconds at a time: subscribing is enough for the mailbox to hand
over whatever is waiting, so a hundred quiet conversations are each visited
about every eight minutes. Raising those numbers means raising both server
limits first, and the reason they are low is not a mistake: one address
holding many sockets is the shape of a denial of service.

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
