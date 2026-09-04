# App Encryption Documentation

What Apple asks for, and why this application cannot skip it. The document
below is the one uploaded to **App Store Connect → App Information → App
Encryption Documentation**, which is what unblocks a build whose `Info.plist`
declares `ITSAppUsesNonExemptEncryption` as true.

Regenerate the PDF Apple wants from this file with:

    cupsfilter docs/EXPORT-COMPLIANCE.md > Rotelyx-Chat-Encryption-Documentation.pdf

`docs/JURISDICTIONS.md` has the reasoning behind the answers; this is the
statement of fact that follows from it. **Neither is legal advice.**

## Why it is required at all

Apple's own wording lists two triggers, and this application meets the second:

  * algorithms that are proprietary or not accepted as standard by an
    international standards body — **not this application**, everything here is
    an RFC or a FIPS
  * standard algorithms used **instead of, or in addition to**, the encryption
    inside Apple's operating system — **this one**, because the protocol is
    compiled into the binary rather than called out to the platform

That is the same reason `ITSAppUsesNonExemptEncryption` is true rather than
false. Declaring false would be a false statement to Apple and, through them, to
the United States Bureau of Industry and Security, and it would be false for a
reason anybody can check by reading the repository.

## The "App Purpose" field, which comes before the upload

App Store Connect asks for it as step 1 of 3 and will not take the document
until it has one. It is answered here rather than retyped each release, because
it has to keep saying the same thing the document says: a purpose and a
document that disagree is what makes a reviewer read both closely.

> Rotelyx Chat is a private messaging application. People use it to exchange
> text messages, pictures and voice calls with contacts they have paired with
> directly, device to device.
>
> Encryption is the application's core function rather than an incidental
> feature. Every message is encrypted end-to-end on the sending device and
> decrypted only on the receiving device, so the mailbox server that carries it
> cannot read it, and neither can we. The application implements this itself
> rather than calling the operating system: it uses the Messaging Layer Security
> protocol (IETF RFC 9420) for group key agreement, X25519 (IETF RFC 7748) and
> ML-KEM-768 (NIST FIPS 203) combined as the X-Wing hybrid for key exchange, and
> ChaCha20-Poly1305 (IETF RFC 8439) for message encryption. Message history
> stored on the device is encrypted at rest under a key derived from the user's
> passphrase with Argon2id (IETF RFC 9106).
>
> Because the protocol is compiled into the application rather than accessed
> through the operating system, the application declares
> ITSAppUsesNonExemptEncryption as true. Every algorithm listed is a published
> international standard; none is proprietary or of our own design. The complete
> cryptographic source code is publicly available, without charge or
> registration, at https://github.com/MaliosDark/rotelyx
>
> The application has no user accounts, requires no phone number or email
> address, holds no user directory, and contains no analytics, advertising or
> crash reporting library. It is distributed free of charge through the App
> Store to the general public.

Say nothing about military or government use. It is not true here and it is the
answer that moves the classification to a different branch.

---

# Rotelyx Chat — App Encryption Documentation

Submitted by: ideoa services uk ltd
Apple Team ID: WV2C9Q74L6
Apple ID: 6808406187
Bundle ID: com.rotelyx.ios

## 1. Summary

Rotelyx Chat implements end-to-end encrypted messaging. It does not rely solely
on the encryption provided by the operating system: the application ships its
own implementation of the algorithms below, compiled into the binary as a static
library.

`ITSAppUsesNonExemptEncryption` is therefore declared **true** in the
application's `Info.plist`. The application does not qualify for the exemption
that covers software calling only the encryption already present in the
operating system, and no such claim is made here.

## 2. The encryption used, and its published standard

Every algorithm in this application is publicly specified by an international
standards body. None is proprietary and none is unpublished.

| Algorithm | Purpose | Published specification |
|---|---|---|
| MLS (Messaging Layer Security) | Group key agreement and message protection | IETF RFC 9420 |
| X25519 | Elliptic-curve key agreement | IETF RFC 7748 |
| ML-KEM-768 | Post-quantum key encapsulation | NIST FIPS 203 |
| X-Wing | Hybrid KEM combining X25519 and ML-KEM-768 | Published IETF draft, with an accompanying public paper |
| ChaCha20-Poly1305 | Authenticated encryption | IETF RFC 8439 |
| Argon2id | Password-based key derivation | IETF RFC 9106 |

There is no cryptography of the submitter's own design and no modification to
any of the above. "Non-standard cryptography" as the U.S. Export Administration
Regulations define it — proprietary or unpublished cryptographic functionality
— is not present in this application.

## 3. Publicly available source code

The complete cryptographic implementation is published as open source and is
available to the general public without restriction, without charge and without
registration, at:

**https://github.com/MaliosDark/rotelyx**

The relevant components are under `crates/`: `rotelyx-crypto` holds the MLS
group layer, the X-Wing hybrid and the key schedule, and `rotelyx-mobile` is the
C ABI through which the application calls them.

The client application source is published at:

**https://github.com/MaliosDark/rotelyx-chat**

Because the encryption source code is publicly available and the cryptography is
standard rather than non-standard, this software falls under the treatment the
EAR applies to publicly available encryption source code.

## 4. What the application does with encryption

  * Messages are sealed on the sending device and opened on the receiving
    device. No server holds a key and no server can read a message.
  * The message store on the device is encrypted at rest.
  * The transport to the user's own mailbox server is protected with TLS
    provided by the operating system, in addition to the end-to-end layer.

The application collects no user data, has no user accounts, requires no phone
number or email address, and contains no analytics, advertising or crash
reporting library.

## 5. Distribution

The application is mass-market software, distributed through the App Store to
the general public at no charge. It is not designed or modified for government
end use.

---

This document states the technical facts of the application's encryption. It is
not legal advice, and the submitter is responsible for its own export
classification.
