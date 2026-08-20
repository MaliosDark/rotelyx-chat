# How Rotelyx works, from nothing

This document exists because Rotelyx is not designed like any messenger people
have used, and that difference is hard to see from the screens. Here is the
whole mental model.

---

## 1. The difference underneath

Every encrypted messenger that exists solves the same problem the same way: it
encrypts the content and lets a server know who talks to whom.

That server has to exist because the user types a phone number or a username,
and something has to turn that into a particular person. That something is a
directory, and a directory is a list of who is who.

WhatsApp encrypts the content and holds your entire address book. Signal
encrypts the content, holds your number, and spent years arranging to hold
nothing else. In both cases the encryption protects the *what* and does not
protect the *who with whom*, which is the most revealing fact about a
conversation and the one thing content encryption never hides.

**Rotelyx has no directory.** There is nothing to look anyone up in, no account,
no number. That has one direct consequence, and it has to be understood before
anything else:

> A conversation cannot begin by finding somebody. It has to begin because two
> people arrive at the same place.

Everything unusual about the application follows from that.

---

## 2. The blind mailbox

There is a server. It is called the mailbox and it does one thing: it holds an
envelope under a tag until somebody collects it.

What the mailbox does **not** have:

- No accounts.
- No knowledge of who deposited.
- No sight of any envelope's contents.
- No history. A collected envelope is removed, an uncollected one expires.

What it **does** see: which tags are polled together, and when. That is inherent
to any store-and-forward system, and it is the reason the tags rotate every hour
and cannot be linked to each other without the group key.

A tag is a locker number. Knowing that locker 47 opened at three in the
afternoon does not say whose it is.

---

## 3. The meeting place

A **meeting place** is one mailbox tag, derived from a string both sides know.

```
    shared string  ──▶  derivation  ──▶  mailbox tag
    "blue apricot"                       a3f0...9c21
```

The derivation runs one way. The mailbox sees the tag and cannot get back to the
string.

Both sides derive the same tag, arrive there, and exchange keys. The mailbox
sees two parties meet at an address it cannot connect to either of them.

There are three ways to agree on the string. Only how it travels changes.

### 3.1 A QR code

One side shows, the other scans. The string is 120 random bits, so it cannot be
guessed. This is the one to use when the two people are in the same room.

### 3.2 A phrase

Both sides type the same words. Convenient over a phone call, and weaker: a
phrase a person invents can be guessed by somebody who knows them.

### 3.3 An invitation

A long block of text carrying the keys directly, for sending through some other
application. It is the only one of the three that will not fit in a QR, and
section 5 explains why.

---

## 4. What the QR carries, and what it does not

This is where almost everybody's mental picture goes wrong, so it is worth being
explicit.

**The QR does not carry keys. It carries an address.**

Specifically, this:

```
    RTLX1 VR3A CHNM DPM4 V7LP YUF3 5HK6
    └───┘ └──────────────────────────┘
    prefix          120 random bits
```

Twenty-nine characters. The prefix is there so the application can tell one of
its codes from every other QR in the world before it tries to use it.

That is all of it. Not a key, not an identity, not a secret worth anything
tomorrow. It is a table number in a cafe: it exists so two people sit at the
same one, and it stops meaning anything once they have sat down.

Mechanically, scanning is exactly the same operation as typing a phrase, except
a random generator chose the phrase instead of a person. That is why it runs on
the pairing path that was already tested.

### What somebody who sees your QR can do

Reach the meeting place before your contact and complete the handshake in their
stead.

This is not a flaw that can be patched. It is what it means to have no authority
vouching for identities. Show the code to one person, and compare the safety
number afterwards. Section 6 explains why that catches it.

---

## 5. Why the invitation will not fit in a QR

This question has an exact numeric answer.

An invitation carries an X-Wing public key. X-Wing is ML-KEM-768 bolted to
X25519, and its public key is **1216 bytes**, because that is what a key that
resists a quantum computer costs. With the MLS key package beside it and two
layers of base64, the invitation comes to roughly **3000 characters**.

A QR code has these ceilings:

| Configuration | Capacity |
|---|---|
| Version 40, low correction (the absolute maximum) | 2953 bytes |
| Version 40, high correction | 1273 bytes |

The invitation does not fit even in the best case. And if it did, version 40 is
177 modules across: at any reasonable size on screen each module is under a
pixel and a half, so it would be unreadable long before it was impossible.

So the QR carries a 29-character address, the two sides meet at the mailbox, and
the keys travel over that, where their size costs nothing.

---

## 6. The safety number

It is the only check in the application that authenticates anyone.

After pairing, both devices compute a fingerprint of the conversation. If the
two fingerprints match, both are in the same group. If somebody got in between,
you would be in two different groups and the fingerprints would not match.

**It has to be compared over a different channel.** Read it aloud on a phone
call, say it in person, send it through another application. Comparing it inside
the conversation itself proves nothing, because that is precisely the
conversation in doubt.

It is the first thing the conversation screen shows, not something behind a
details panel. That is deliberate: it is the only step that turns *I am talking
to somebody* into *I am talking to who I think*.

---

## 7. The logo inside the QR, and why it does not break it

A QR code carries considerably more than it encodes. At the highest of the four
error-correction levels, close to a third of the symbol can be destroyed and the
payload still comes back intact, because Reed-Solomon reconstructs it.

That budget is what pays for the logo. The modules it covers are not a hole in
the data, they are damage the arithmetic repairs.

Two things make it safe rather than lucky:

1. The correction level is fixed at the highest setting by hand, not left to the
   encoder's judgement.
2. The logo plate is 24 percent of the width, so under 6 percent of the area,
   and nowhere near the three corner squares a scanner needs to find the code at
   all.

And it is not taken on faith. A test builds the same symbol, destroys exactly
the square the application draws, photographs it at an angle under poor light,
and decodes it. If the plate ever grew too large, that test fails.

---

## 8. The scanner is ours

Every QR scanner package for Flutter web downloads a JavaScript decoder from a
content delivery network the first time the camera opens. The
Content-Security-Policy in `web/index.html` blocks that, correctly: the promise
this application makes is that it talks to nobody but its own mailbox.

The alternative would have been to relax the policy for one feature. Reading a
QR code is arithmetic on a bitmap. It does not need a server, so it does not get
one.

The decoder lives in `lib/qr/` and does four things:

1. **Binarise.** Decide light or dark per pixel, with a threshold computed per
   eight-by-eight block, because a single threshold fails the moment one side is
   in shadow.
2. **Find the three corners.** Every QR carries three identical squares. Their
   property is a run of dark, light, dark, light, dark in the ratio 1:1:3:1:1,
   and that ratio holds along any line through the centre, at any rotation. That
   is what makes them findable without knowing the orientation.
3. **Work out the geometry.** Three corners give the size, the rotation and the
   module pitch. The fourth corner is where a camera held at an angle bends the
   square into a trapezium, so the nearest alignment square is located.
4. **Sample.** Walk the grid and read the pixel each module lands on, five reads
   per module and a vote, because at seven pixels to a module a single read
   drifts into the neighbour.

Frames are not uploaded, not stored and not encoded. Each is overwritten by the
next, and the camera stops the instant the screen closes.

What is proven, and which test proves it:

| Test | What it establishes |
|---|---|
| 160 combinations of version and level, round trip | The tables and the arithmetic are right |
| 72 rotations, 0 to 355 degrees | Orientation does not matter |
| A 40 percent foreshortened pose | Reads when held off to one side |
| Blur, sensor noise, a lighting gradient | Reads on a poor camera in poor light |
| Pure noise, 52 frames | Never invents a reading |
| A screenshot of the running application | What the app draws can actually be scanned |

Measured over 400 random codes in the most severe pose, one failed: a per-frame
rate of 99.75 percent, against a camera that examines eight frames a second.

---

## 9. Where what you write lives

On this device, and nowhere else.

The mailbox keeps nothing. There is no server-side history, no account to
restore from, and no other device holding a copy unless you made one. If this
store loses a conversation, the conversation is gone.

That is the cost of a design where the operator knows nothing, and it is the
right cost. But it makes durability a feature rather than a detail.

The passphrase does one thing: it derives the key that seals what this device
writes down, with Argon2id at 64 MiB. That is why it takes close to a second,
and that second is the point.

Keeping history means writing readable message text to disk, encrypted, in a
profile that can be copied. Everywhere else in Rotelyx plaintext exists only in
memory, for the moment it is on screen. That is a real change to what an
attacker with the device gets, so it is opted into deliberately and explained on
the screen rather than buried in settings.

Without a passphrase the application still works. It simply forgets on reload,
which is the stronger position and an inconvenient default.

---

## 10. One page of it

- There is no directory, so nobody gets looked up. Somebody waits in a place.
- The place is a mailbox tag derived from a shared string.
- The QR carries that string, 29 characters. It carries no keys.
- The keys travel over the mailbox, which cannot read them.
- The long invitation exists for when you cannot be in the same room, and it
  does not fit in a QR because a post-quantum key is 1216 bytes.
- None of that proves who you are talking to. The safety number does, compared
  over another channel.
- What you write lives here and nowhere else.
