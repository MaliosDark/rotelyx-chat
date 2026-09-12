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

  /// A message was changed by whoever sent it.
  edited,

  /// Somebody handed over their copy of what was said before a newcomer
  /// arrived.
  ///
  /// # Why a conversation cannot simply have a history
  ///
  /// Forward secrecy means nobody keeps the material to rebuild one. A member
  /// added at epoch `n` cannot read anything sealed under `n-1`, and that is a
  /// promise rather than a gap: it is why a newcomer to a group cannot read
  /// what was said before they were let in.
  ///
  /// So there is nothing the *group* can give them. There is only what a
  /// *person* has on their device, and that person choosing to hand a copy
  /// over.
  ///
  /// # Why the whole group sees it
  ///
  /// Because what arrives is one member's copy, not a fact the group asserts,
  /// and the difference matters to everybody who spoke. Somebody who said
  /// something on the understanding that four people heard it is entitled to
  /// know when a fifth is given it.
  ///
  /// People do this anyway, with screenshots, and the group learns nothing.
  /// This is the same act done where it can be seen.
  history,

  /// Somebody is asking the group to admit a person, and where to leave the
  /// welcome if it is agreed.
  ///
  /// # Why the request travels beside the proposal instead of inside it
  ///
  /// The MLS proposal is what makes the addition real, and it carries a key
  /// package and nothing else. Two things the other members need are not in
  /// it: the name to show somebody making a decision, and the address to leave
  /// the welcome at once they have made it.
  ///
  /// That address is the asking member's meeting place, and it has to travel
  /// because whoever confirms is not whoever was asked. A meeting tag is a
  /// hash of a phrase nobody stores, so a member that did not issue the
  /// invitation has no way to work it out.
  pendingAddition,

  /// Somebody is telling whoever runs this conversation that a message in it
  /// should not be here.
  ///
  /// # Why a report goes to the group and not to us
  ///
  /// The App Store requires a way to report objectionable content, and the
  /// obvious reading of that is a report that reaches whoever publishes the
  /// application. Here that is impossible and pretending otherwise would be a
  /// button that does nothing: nobody outside a conversation can read a word
  /// of it, including us, and a report we could act on would mean a
  /// conversation we could read.
  ///
  /// So it goes where the only people who can already read it are. A
  /// conversation's admins see what was reported and can take the member out,
  /// which is a real commit and not a local hiding. SimpleX answers the same
  /// requirement the same way and ships on the App Store with it.
  ///
  /// # Who else sees it
  ///
  /// Everybody. An application message is sealed for the group, and a group
  /// is the only address MLS has: there is no way to send this to two members
  /// out of six. The screen says so before anybody sends one, because a
  /// report somebody believed was private and was not is worse than no report
  /// at all.
  ///
  /// In a conversation of two there is nobody to tell who is not the person
  /// being reported, which is why the screen offers blocking there instead.
  report,
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

  /// Somebody is in the call now.
  ///
  /// # Why a call with more than two people needs this
  ///
  /// A ring goes to the whole group, so in a group of five it rings four
  /// phones. [answered] is read only by the device that placed the call, so
  /// when one of the four picked up, the other three heard nothing: they went
  /// on ringing until a timer gave up, each believing the call was still
  /// theirs to answer.
  ///
  /// This is the announcement they were missing. A call with more than two
  /// people is a room rather than an offer: it stops ringing at anybody and
  /// starts being a thing that is happening, which they can join or not.
  ///
  /// Sent by whoever joins, including the person who started it, so the room's
  /// membership is what everybody has seen rather than something one device
  /// keeps and the rest are told about.
  joined,

  /// Somebody has left the call, which is not the call ending.
  ///
  /// [ended] means the call is over for everybody. In a room of four, one
  /// person hanging up is three people still talking, and an interface that
  /// treats the two the same empties a room because somebody's battery died.
  left,
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

  /// A copy of what was said before, handed over on purpose.
  ///
  /// [messages] is JSON, base64 so that it survives a field separator it would
  /// otherwise contain.
  factory Signal.history(String messagesJson) => Signal(
        kind: SignalKind.history,
        fields: [base64Encode(utf8.encode(messagesJson))],
      );

  /// Ask the group to admit somebody, saying who and where to answer.
  ///
  /// The name is what a person reads before deciding. It is what the joiner
  /// called themselves, so it is worth exactly what an unverified name is
  /// worth, and an interface showing it has to say so.
  factory Signal.pendingAddition({
    required String meetingTag,
    required String name,
  }) =>
      Signal(
        kind: SignalKind.pendingAddition,
        fields: [meetingTag, base64Encode(utf8.encode(name))],
      );

  /// Where to leave the welcome for somebody being admitted, or null when this
  /// was not that.
  String? get pendingMeetingTag =>
      kind == SignalKind.pendingAddition && fields.isNotEmpty ? fields.first : null;

  /// What the person asking to be admitted calls themselves.
  String get pendingName {
    if (fields.length < 2) return '';
    try {
      return utf8.decode(base64Decode(fields[1]));
    } on Object {
      return '';
    }
  }

  /// The messages somebody handed over, as JSON, or null when unreadable.
  String? get handedHistory {
    if (fields.isEmpty) return null;
    try {
      return utf8.decode(base64Decode(fields.first));
    } on Object {
      return null;
    }
  }

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
  /// Report the message sent at [at], with a reason somebody chose from a
  /// list rather than typed.
  ///
  /// A list, because a free text box in a report is a place to put abuse of
  /// its own, and because a reason nobody reads is worth less than a reason
  /// that can be counted.
  factory Signal.report(DateTime at, String reason) => Signal(
        kind: SignalKind.report,
        fields: [at.millisecondsSinceEpoch.toString(), reason],
      );

  /// When the reported message was sent, or null where this is not a report.
  DateTime? get reportedAt {
    if (kind != SignalKind.report || fields.isEmpty) return null;
    final at = int.tryParse(fields.first);
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// Why, in the words of whoever reported it.
  String get reportReason =>
      kind == SignalKind.report && fields.length > 1 ? fields[1] : '';

  factory Signal.retract(DateTime at) => Signal(
        kind: SignalKind.retract,
        fields: [at.millisecondsSinceEpoch.toString()],
      );

  /// Which message, by its author's timestamp.
  DateTime get retractedAt => DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(fields.isEmpty ? '' : fields.first) ?? 0);

  // --- edited ------------------------------------------------------------------

  /// Replace what a message said.
  ///
  /// # Why the old text is not kept
  ///
  /// Other messengers keep an edit history and show "edited" with the previous
  /// version behind a tap. That is a reasonable choice for a product whose
  /// argument is accountability. It is the wrong one here: it means a message
  /// somebody deliberately changed is still on both devices in its first form,
  /// and the person who edited it believes it is not.
  ///
  /// So the old text is replaced rather than appended to. The bubble is marked
  /// as edited, because hiding that would let somebody quietly rewrite what
  /// they said, and the mark is the whole of what is kept.
  ///
  /// Only the author may edit, checked on receipt rather than trusted.
  factory Signal.edited(DateTime at, String text) => Signal(
        kind: SignalKind.edited,
        fields: [at.millisecondsSinceEpoch.toString(), text],
      );

  DateTime get editedAt => DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(fields.isEmpty ? '' : fields.first) ?? 0);

  /// The replacement. Anything after the second separator, so a body that
  /// contains one is not truncated.
  String get editedText => fields.length > 1 ? fields.sublist(1).join(_sep) : '';

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
