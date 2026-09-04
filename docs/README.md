<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/images/rotelyx-wordmark-dark.png">
  <img src="../assets/images/rotelyx-wordmark-light.png" alt="Rotelyx" height="34">
</picture>

# Documentation

Grouped by the question it answers rather than alphabetically, because nobody
arrives here knowing the filename.

The client is `rotelyx_chat`, a Flutter application over a Rust engine. The
protocol it speaks lives in [the protocol
repository](https://github.com/MaliosDark/rotelyx), and anything about the
cryptography, the mailbox or the relay is documented there.

## Start here

| If you want to | Read |
|---|---|
| Understand what this is, without jargon | [HOW-IT-WORKS.md](HOW-IT-WORKS.md) |
| See it, screen by screen | [SCREENS.md](SCREENS.md) |
| Know what is built and what is not | [BACKLOG.md](BACKLOG.md) |

## Building and running it

| If you want to | Read |
|---|---|
| Build the engine for Android and iOS | [NATIVE.md](NATIVE.md) |
| Know why the browser build refuses to load a font from a CDN | [CSP.md](CSP.md) |
| Understand what is kept on the device and what is not | [PERSISTENCE.md](PERSISTENCE.md) |
| Know how a device is woken when the application is closed | [PUSH.md](PUSH.md) |

## Shipping it

| If you want to | Read |
|---|---|
| Put it in the two stores | [RELEASING.md](RELEASING.md) |
| Know where it can legally be offered | [JURISDICTIONS.md](JURISDICTIONS.md) |
| Answer Apple's encryption documentation | [EXPORT-COMPLIANCE.md](EXPORT-COMPLIANCE.md) |
| Report something you found | [../SECURITY.md](../SECURITY.md) |
| Send code | [../CLA.md](../CLA.md) |

## The two documents worth reading even if you read nothing else

**[HOW-IT-WORKS.md](HOW-IT-WORKS.md)**, because this client is not designed like
any messenger people have used and the difference does not show on the screens.
There is no account, no directory and no identifier anybody looks you up by, and
every unfamiliar thing in the interface follows from one of those three.

**[PUSH.md](PUSH.md)**, because it is where the two platforms stop being the
same product. Android holds its own connection and notifies itself, so nothing
outside the phone learns a message arrived. iOS does not permit that, so it is
woken by Apple, and what Apple learns is written out rather than glossed.

## What is documented elsewhere

The protocol, the mailbox, the relay, the codec and the threat model are in
[the protocol repository](https://github.com/MaliosDark/rotelyx). This one is
the client: the screens, the platform work under them, and what it takes to
ship it.
