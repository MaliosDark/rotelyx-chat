<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/images/rotelyx-wordmark-dark.png">
  <img src="../assets/images/rotelyx-wordmark-light.png" alt="Rotelyx" height="34">
</picture>

# Privacy policy

Last updated: 12 September 2026. Rotelyx is published by Ideoa Labs, and the
address for anything in this document is <contact@ideoa.co.uk>.

Most privacy policies are a list of what is collected. This one is mostly a
list of what is not, so it starts there and then says what the exceptions are,
because a policy with no exceptions is one nobody should believe.

## There is no account

No name, no email address, no phone number, no username. Nothing identifies
you to us and there is nothing to sign in to. Two people pair by scanning a
code or saying a phrase to each other, and what comes out of that is a key on
each phone.

This is not a setting. There is no code path that creates an account, which is
why there is also no account to delete.

## What we cannot see

**Your messages.** They are encrypted on your device and decrypted on the
other person's. The keys are on those two phones. The mailbox that carries an
envelope holds an opaque blob and has no way to open one, and neither do we.

**Who you talk to.** A message is deposited at an address derived from a
secret the two of you share, and that address changes every hour. The mailbox
sees envelopes arriving at addresses; it cannot tell that two addresses an hour
apart belong to the same conversation, and it is deliberately never told which
device is which.

**When you are online.** There is no presence, no last seen, and no typing
indicator sent anywhere.

## What the mailbox necessarily sees

Running a server means seeing some things, and pretending otherwise would be
the dishonest part of a document like this.

| What | Why it is unavoidable | How long |
|---|---|---|
| That a device connected, and from which network address | A socket has two ends | Not written down |
| The rotating addresses a device subscribes to | It has to know what to hand over | For the life of the connection |
| Sealed envelopes | They are being carried | Up to seven days on the free tier, then deleted |
| A push token, where you turned on delivery while the app is closed | Apple and Google will not deliver without one | Until you turn it off, or until the service reports the device gone |

The push token is stored on its own, with no address and no conversation
beside it. That separation is the point: a token is stable for months and an
address rotates hourly, and storing them together would undo the rotation.

## What is on your phone

Your conversations, your keys and your settings. Encrypted, with a key held by
the device's own secure storage, and nothing is copied to iCloud or to Google
Drive: the container is marked as excluded from backup.

Ghost mode writes nothing to disk at all. When you quit, what happened in that
session is gone from that phone.

## What is not here at all

No analytics. No crash reporter. No advertising identifier. No third party
SDK that phones home. The only host the application contacts is the mailbox
you are using, and a relay while a call is running.

Sending a photograph, a sticker or a GIF calls nobody: the picture is shrunk on
your phone and sealed like any other message. There is no image search and no
sticker service.

## Children

Rotelyx is not directed at children and is rated accordingly.

## What you can ask us for

Under the UK GDPR and the equivalents elsewhere you may ask what we hold about
you. The honest answer is that we hold nothing tied to you, because nothing
identifies you to us. If you have written to us, we hold that correspondence
and will delete it on request.

Write to <contact@ideoa.co.uk>. We answer within 24 hours.

## Changes

This document changes when the application does. The date at the top is when it
last did.
