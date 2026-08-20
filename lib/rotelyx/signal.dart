/// Messages that are not something a person wrote.
///
/// A read receipt, a reaction and a profile picture all need to travel the same
/// way a sentence does, and none of them should appear in the conversation as
/// text. This is the one place that decides which is which.
///
/// # Why they are messages at all
///
/// There is no side channel. Everything goes through MLS as an application
/// message, which means a receipt is exactly as protected as the sentence it
/// refers to, and the mailbox cannot tell the two apart: both are an envelope
/// of the same padded size arriving at the same tag.
///
/// A separate channel would be cheaper and would be a second thing to key, to
/// authenticate and to get wrong.
///
/// # What each one costs
///
/// A fan-out per event, the same as a message. That is the real reason read
/// receipts are off by default and typing indicators do not exist here: a
/// receipt is one extra envelope per message read, and a typing indicator would
/// be a stream of them describing when somebody is holding their phone.
///
/// Signal has a documented issue of this shape, where reactions combined with
/// delivery receipts let an observer infer activity patterns and correlate
/// accounts. The lesson taken here is not that receipts are forbidden, it is
/// that they are a choice with a cost, so they are opt in per conversation and
/// the setting says what it reveals.
library;

import 'dart:convert';
import 'dart:typed_data';

/// What kind of control message this is.
enum SignalKind {
  /// The other side has seen up to a point in the conversation.
  read,

  /// A reaction was added to, or removed from, a message.
  reaction,

  /// The sender's display picture, small enough to travel inline.
  profile,

  /// Named self destructing messages have been read, so the sender's own
  /// copies may start expiring.
  burnRead,

  /// Somebody is calling, has answered, has declined, or has hung up.
  call,

  /// A message was withdrawn by whoever sent it.
  retract,
}

/// What a [SignalKind.call] is saying.
enum CallSignal {
  /// Ringing. Sent by whoever placed it.
  ringing,

  /// Answered. The media path opens on both sides when this arrives.
  answered,

  /// Not now. Distinct from [ended] because an interface should say
  /// "declined" rather than "call ended" when somebody actively said no.
  declined,

  /// Over, whoever ended it.
  ended,

  /// Still ringing, sent every few seconds while it is.
  ///
  /// Without it, a caller who loses their connection mid-ring leaves the other
  /// phone ringing forever, and the only thing that stops it is somebody
  /// answering a call that is not there.
  stillRinging,
}

const String _marker = 'rx-signal';
const String _sep = '\x1f';

/// A control message.
class Signal {
  const Signal({required this.kind, required this.fields});

  final SignalKind kind;

  /// Kind-specific values, in the order each kind documents.
  final List<String> fields;

  // --- read ------------------------------------------------------------------

  /// Seen everything up to and including the message at [at].
  ///
  /// A high-water mark rather than one receipt per message: it is a single
  /// envelope however many messages were read, and it cannot be used to time
  /// each one individually.
  factory Signal.read(DateTime at) => Signal(
        kind: SignalKind.read,
        fields: [at.millisecondsSinceEpoch.toString()],
      );

  DateTime get readThrough => DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(fields.isEmpty ? '' : fields.first) ?? 0);

  // --- reaction --------------------------------------------------------------

  /// [emoji] on the message identified by its author and timestamp.
  ///
  /// Identified that way because there is no message id on the wire, for the
  /// same reason a reply carries a quote: an id is a handle the mailbox could
  /// use to correlate envelopes.
  factory Signal.reaction({
    required String emoji,
    required DateTime at,
    required bool remove,
  }) =>
      Signal(kind: SignalKind.reaction, fields: [
        emoji,
        at.millisecondsSinceEpoch.toString(),
        remove ? '1' : '0',
      ]);

  String get emoji => fields.isEmpty ? '' : fields[0];

  DateTime get reactionAt => DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(fields.length > 1 ? fields[1] : '') ?? 0);

  bool get removing => fields.length > 2 && fields[2] == '1';

  // --- profile ---------------------------------------------------------------

  /// A picture, already scaled down by the sender.
  ///
  /// Sent rather than fetched, because there is nowhere to fetch it from: no
  /// account, no directory and no server that holds anything. It arrives the
  /// same way a photograph does and is kept locally.
  factory Signal.profile(Uint8List png) =>
      Signal(kind: SignalKind.profile, fields: [base64Encode(png)]);

  Uint8List? get picture {
    if (fields.isEmpty) return null;
    try {
      return base64Decode(fields.first);
    } on Object {
      return null;
    }
  }

  // --- burnRead ---------------------------------------------------------------

  /// These expiring messages have been read.
  ///
  /// Sent whatever the conversation's receipt setting says, and that is worth
  /// being plain about rather than quiet about. A self destructing message
  /// cannot destroy itself on both devices without one of them saying "seen",
  /// so choosing the timer is choosing to send this. What it reveals is
  /// bounded: it names only messages that were already going to announce their
  /// own reading by vanishing, it says nothing about anything else in the
  /// conversation, and unlike [Signal.read] it is not a high water mark, so it
  /// discloses nothing about messages the sender did not put a timer on.
  ///
  /// Several identifiers travel in one envelope, because reading a
  /// conversation with four expiring messages in it should cost one deposit
  /// and not four.
  factory Signal.burnRead(Iterable<String> ids) =>
      Signal(kind: SignalKind.burnRead, fields: ids.toList());

  /// Which messages the other side has read. See [Ephemeral].
  List<String> get burnIds => fields.where((f) => f.isNotEmpty).toList();

  // --- retract -----------------------------------------------------------------

  /// Withdraw a message, named by when its author sent it.
  ///
  /// # What this can and cannot do, said plainly
  ///
  /// It asks. The other side's copy goes because their client removes it, and
  /// nothing here reaches into somebody else's device. A recipient running a
  /// modified client, or one who took a photograph, keeps it.
  ///
  /// That is the same limit self destructing messages have and it is worth
  /// stating in the interface rather than implying that a message can be
  /// unsent. What it does deliver is real: on an ordinary client the message is
  /// gone from both logs, so a phone handed over later does not have it.
  ///
  /// Only the author may withdraw. A retract naming somebody else's message is
  /// ignored, because otherwise anybody in a group could delete anybody's
  /// history.
  factory Signal.retract(DateTime at) => Signal(
        kind: SignalKind.retract,
        fields: [at.millisecondsSinceEpoch.toString()],
      );

  /// Which message, by its author's timestamp.
  DateTime get retractedAt => DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(fields.isEmpty ? '' : fields.first) ?? 0);

  // --- call -------------------------------------------------------------------

  /// Ringing, answering, declining, hanging up.
  ///
  /// # Why this travels as a message
  ///
  /// Because there is nothing else for it to travel on. A call invitation over
  /// a side channel would be a second thing to key and authenticate, and it
  /// would be the one an operator could see while the conversation stayed
  /// hidden. Sent through MLS, an invitation to a call is exactly as protected
  /// as the call, and the mailbox sees one more envelope of the same padded
  /// size.
  ///
  /// # What it costs, stated
  ///
  /// A fan-out per state change, and a heartbeat while ringing. That is more
  /// envelopes in thirty seconds than a conversation usually sends in an hour,
  /// and it is visible as a burst. There is no way around it: a phone that is
  /// not being told cannot ring.
  /// [address] rides on the ring and on the answer, because a call needs both
  /// the agreement and somewhere to connect, and a second signal for the
  /// second half is a second thing to lose.
  ///
  /// It is already filtered where it is produced: no IP addresses, just the
  /// relay. Sending it discloses nothing about where this device is.
  factory Signal.call(CallSignal what, {String id = '', String address = ''}) =>
      Signal(
        kind: SignalKind.call,
        fields: [what.name, id, address],
      );

  /// Which of the five, or null when it is from a build with more of them.
  CallSignal? get callSignal {
    if (fields.isEmpty) return null;
    final match = CallSignal.values.where((c) => c.name == fields.first);
    return match.isEmpty ? null : match.first;
  }

  /// Which call this is about.
  ///
  /// Two people pressing call at the same moment produce two calls, and
  /// without this the answer to one ends the other. Sixteen random characters
  /// from the same generator a burning message uses.
  String get callId => fields.length > 1 ? fields[1] : '';

  /// Where to connect, on a ring or an answer. Empty on the others.
  String get callAddress => fields.length > 2 ? fields[2] : '';

  // --- wire ------------------------------------------------------------------

  String encode() {
    String clean(String s) => s.replaceAll(_sep, ' ');
    return [_marker, kind.name, ...fields.map(clean)].join(_sep);
  }

  /// Read one back, or null when this is something a person wrote.
  static Signal? decode(String body) {
    if (!body.startsWith('$_marker$_sep')) return null;
    final parts = body.split(_sep);
    if (parts.length < 2) return null;

    final kind = SignalKind.values.where((k) => k.name == parts[1]);
    // An unknown kind is a newer build talking to an older one. Dropped rather
    // than shown, so a future feature does not appear as a line of gibberish
    // in somebody's conversation.
    if (kind.isEmpty) return null;

    return Signal(kind: kind.first, fields: parts.sublist(2));
  }

  /// Whether this body should be hidden from the conversation.
  static bool isControl(String body) => body.startsWith('$_marker$_sep');
}
