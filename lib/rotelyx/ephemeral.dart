/// Messages that destroy themselves.
///
/// # When the clock starts, and why that is the hard part
///
/// It starts on **both** devices at the same event: the moment the recipient
/// reads it. Not when it was sent, and not when it arrived.
///
/// Arrival is wrong because a message that begins expiring inside a mailbox is
/// a message anybody can destroy by keeping its recipient offline. Sending is
/// wrong because the two copies then count down from different moments, and
/// the sender watches theirs burn with no idea whether the other one was ever
/// opened. The person who set the timer meant "gone a minute after you have
/// seen this", and that sentence has one starting point, not two.
///
/// So the recipient starts their clock on read and sends back an
/// acknowledgement, and the sender's copy holds, showing nothing but a flame,
/// until that acknowledgement arrives. See [Signal.burnRead].
///
/// That is why the duration travels and the deadline does not. A deadline would
/// have to be computed against a clock, and two devices do not share one: a
/// phone half an hour fast would burn everything on arrival. A duration is the
/// same number on both.
///
/// # Why each one carries an identifier
///
/// The acknowledgement has to name the message it is about, and there is
/// nothing already on the wire that does. A timestamp will not serve: each
/// device stamps a message with its own clock, so the sender's copy and the
/// recipient's copy of one sentence disagree about when it happened. The text
/// will not serve either, since saying "ok" twice is normal.
///
/// So the sender draws sixteen random hexadecimal characters and puts them in
/// the body, where both copies inherit the same value. It is scoped to one
/// message inside one already encrypted conversation, it names nothing and
/// nobody, and it is gone with the message it belongs to.
///
/// # What this does not claim
///
/// The other side's copy goes because their client removes it. Nothing here
/// can reach into somebody else's device and nothing pretends to. A recipient
/// who wants a copy has a camera pointed at the screen, and no messenger has
/// ever solved that.
///
/// What it does deliver is honest and worth having: neither device keeps the
/// message afterwards, so a phone picked up later, or handed over later, does
/// not have it.
library;

import 'dart:math';


/// Marks a message body as one that expires.
const String _marker = 'rx-burn';
const String _sep = '\x1f';

/// The choices offered, in seconds. Each is a real answer to a real question
/// rather than a slider that invites fiddling.
const List<int> burnChoices = [
  10,        // read it now
  60,        // one minute
  300,       // five minutes
  3600,      // an hour
  86400,     // a day
  604800,    // a week
];

/// How each one reads.
String burnLabel(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  if (seconds < 86400) return '${seconds ~/ 3600}h';
  if (seconds < 604800) return '${seconds ~/ 86400}d';
  return '${seconds ~/ 604800}w';
}

class Ephemeral {
  const Ephemeral({required this.seconds, required this.body, this.id = ''});

  /// How long after being read it survives.
  final int seconds;

  /// The message itself, which may be a reply or a file.
  final String body;

  /// What the read acknowledgement will name. Identical on both copies.
  final String id;

  /// Wrap [body] so it expires [seconds] after it is read.
  ///
  /// The identifier is drawn here rather than by the caller so that no path
  /// can send an expiring message the acknowledgement cannot refer to.
  factory Ephemeral.wrap({required int seconds, required String body}) =>
      Ephemeral(seconds: seconds, body: body, id: newBurnId());

  /// The identifier is omitted when there is none, rather than sent empty.
  /// An empty field would still be a field, and the decoder would hand back a
  /// body with a separator glued to the front of it.
  String encode() =>
      [_marker, '$seconds', if (id.isNotEmpty) id, body].join(_sep);

  /// Read one back, or null when this message is not going anywhere.
  static Ephemeral? decode(String text) {
    if (!text.startsWith('$_marker$_sep')) return null;
    final parts = text.split(_sep);
    if (parts.length < 3) return null;

    final seconds = int.tryParse(parts[1]);
    // A duration that will not parse is a message from a build that disagrees
    // about the format. Shown rather than burnt: refusing to display it would
    // lose it, and burning it on a guess would lose it faster.
    if (seconds == null || seconds <= 0) return null;

    // An identifier is present when the third field looks like one. Written
    // as a test rather than assumed, so a body that happens to start with
    // sixteen hexadecimal characters is the only thing that can be misread,
    // and a message from a build that predates identifiers still shows.
    final hasId = parts.length > 3 && _looksLikeId(parts[2]);

    return Ephemeral(
      seconds: seconds,
      id: hasId ? parts[2] : '',
      // Anything after the last field is the body, so a body that contains a
      // separator is not truncated.
      body: parts.sublist(hasId ? 3 : 2).join(_sep),
    );
  }

  /// The body, whether or not this message expires.
  static String plain(String text) => decode(text)?.body ?? text;

  /// The identifier of an expiring message, or empty for anything else.
  static String idOf(String text) => decode(text)?.id ?? '';

  /// Whether this message expires.
  static bool isEphemeral(String text) => decode(text) != null;
}

/// How wide an identifier is, in characters.
const int _idLength = 16;

final Random _entropy = Random.secure();

/// A fresh identifier for one expiring message.
///
/// `Random.secure` rather than `Random`, and not because anything is being
/// keyed with it. A predictable value here would let somebody who can see one
/// conversation guess the identifiers in another, and there is no reason to
/// pay attention to that question when the secure generator is one word away.
String newBurnId() {
  const digits = '0123456789abcdef';
  return String.fromCharCodes([
    for (var i = 0; i < _idLength; i++)
      digits.codeUnitAt(_entropy.nextInt(digits.length)),
  ]);
}

/// Thirty two random bytes, as hexadecimal.
///
/// Used for anything that has to be unguessable and is not a key: today, the
/// secret that proves a push revocation came from this device. Twice the width
/// of a burn identifier, because that one only has to be unique within one
/// conversation and this one has to survive being guessed at by anybody who can
/// reach the mailbox.
String newSecret() {
  const digits = '0123456789abcdef';
  return String.fromCharCodes([
    for (var i = 0; i < 64; i++)
      digits.codeUnitAt(_entropy.nextInt(digits.length)),
  ]);
}

bool _looksLikeId(String s) {
  if (s.length != _idLength) return false;
  for (final c in s.codeUnits) {
    final hex = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66);
    if (!hex) return false;
  }
  return true;
}
