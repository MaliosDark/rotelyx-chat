/// The meeting code: what a Rotelyx QR actually contains.
///
/// # Why the QR does not contain the keys
///
/// The obvious design is to put the invitation in the QR. It cannot be done,
/// and the reason is worth writing down so nobody tries again.
///
/// An invitation carries an X-Wing public key. X-Wing is ML-KEM-768 bolted to
/// X25519, and its public key is 1216 bytes, because that is what a key that
/// resists a quantum computer costs. With the MLS key package alongside it and
/// two layers of base64, the invitation comes to roughly three thousand
/// characters.
///
/// A QR code tops out at 2953 bytes, and only at the weakest correction level,
/// at version 40, which is 177 modules across. Raise the correction to the
/// level that lets a logo sit in the middle and the ceiling drops to 1273. The
/// invitation does not fit, and would be unscannable long before it did.
///
/// # What goes in instead
///
/// A meeting code: 120 random bits, written in a 32-character alphabet, 29
/// characters in total. It is not a key and it is not an identity. It is an
/// address at the mailbox, in the same sense as a table number in a cafe.
///
/// Both sides run it through `rendezvousTag`, arrive at the same mailbox tag,
/// and perform the ordinary handshake there. The keys are exchanged over the
/// mailbox, where their size costs nothing.
///
/// # What a meeting code is worth to an attacker
///
/// It is worth exactly one attempt at being first. Whoever reaches the meeting
/// place before the intended person completes the handshake in their place, and
/// nothing in the code prevents that, because a code is not a proof of who is
/// holding it.
///
/// This is the same exposure the typed meeting phrase has, with one difference
/// that matters: a phrase a human chose can be guessed, and 120 random bits
/// cannot. The remaining risk is somebody who *saw* the code, over a shoulder
/// or in a photograph, and the answer to that is the same as everywhere else in
/// this app. Compare the safety number. It is the only step that authenticates
/// anyone, and it is the first thing the conversation screen shows.
library;

import 'dart:math';

/// The prefix, so a scanner can tell a Rotelyx code from any other QR before
/// it tries to use one.
const meetingPrefix = 'RTLX1';

/// The alphabet: base32 as RFC 4648 defines it.
///
/// Two properties earn it the job. Every character is legal in the QR
/// standard's alphanumeric mode, so a future encoder can pack two characters
/// into eleven bits rather than spending eight on each. And it omits 0, 1 and
/// 8, which are the digits people mistake for O, I and B when reading a code
/// aloud down a phone line.
const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// How many random bytes a code carries.
///
/// Fifteen bytes is 120 bits, which is an exact multiple of the five bits a
/// base32 character holds. So the code needs no padding, and it comes to 29
/// characters, which is what keeps the symbol at version 4: 33 modules across.
/// At the size the pairing screen draws it, that is eight screen pixels per
/// module, which a phone camera reads from arm's length without hunting.
///
/// Going to 160 bits would push it to version 5 and buy nothing. 120 bits is
/// already far past any amount of guessing, and this is a secret that lives for
/// the length of one handshake.
const _entropyBytes = 15;

/// Mint a new meeting code.
///
/// [Random.secure] rather than [Random], which is not a detail: the default
/// generator is seeded predictably enough that two devices starting at the same
/// moment can produce the same sequence, and a guessable meeting code is a
/// meeting somebody else can attend.
String newMeetingCode() {
  final random = Random.secure();
  final bytes = List<int>.generate(_entropyBytes, (_) => random.nextInt(256));

  final out = StringBuffer(meetingPrefix);
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_alphabet[(buffer >> bits) & 0x1F]);
    }
  }
  assert(bits == 0, 'entropy must divide into whole base32 characters');
  return out.toString();
}

/// Recognise a meeting code in whatever a scan or a paste produced.
///
/// Returns the code in its canonical form, or null if this is not one.
///
/// Tolerant on the way in and strict on the way out. A camera may read a code
/// somebody wrapped in a link, a person may paste it with a trailing space, and
/// a phone keyboard may have capitalised it or not. None of those are the
/// user's mistake to fix.
String? readMeetingCode(String input) {
  var text = input.trim();

  // A code shared as a link, which is what a person naturally does when they
  // want it to be tappable in whatever app they are pasting into.
  //
  // Only the custom scheme, deliberately. An `https://` form would mean naming
  // a web host inside the client, and `test/no_foreign_infrastructure_test.dart`
  // fails the build over exactly that. It is right to: a hostname in the source
  // is a hostname somebody will eventually fetch.
  const scheme = 'rotelyx://';
  if (text.toLowerCase().startsWith(scheme)) {
    text = text.substring(scheme.length);
  }

  text = text.replaceAll(RegExp(r'[\s\-]'), '').toUpperCase();

  if (!text.startsWith(meetingPrefix)) return null;

  final body = text.substring(meetingPrefix.length);
  if (body.length != (_entropyBytes * 8) ~/ 5) return null;
  for (final unit in body.codeUnits) {
    if (!_alphabet.contains(String.fromCharCode(unit))) return null;
  }

  return '$meetingPrefix$body';
}

/// Break a code into groups for display.
///
/// A 29-character run is unreadable and unspeakable. Groups of four are what
/// people are used to from card numbers and licence keys.
///
/// The prefix stays, as its own group. Dropping it would make the displayed
/// code something [readMeetingCode] refuses, so copying what is on screen would
/// fail in a way nobody could diagnose.
String prettyMeetingCode(String code) {
  final body = code.startsWith(meetingPrefix)
      ? code.substring(meetingPrefix.length)
      : code;
  final groups = <String>[meetingPrefix];
  for (var at = 0; at < body.length; at += 4) {
    groups.add(body.substring(at, min(at + 4, body.length)));
  }
  return groups.join(' ');
}
