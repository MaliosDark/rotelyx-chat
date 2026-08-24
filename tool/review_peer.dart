/// A peer that answers, for anybody who has to review this application.
///
/// # What this is for
///
/// There is no account here and no directory, so a person handed this app on
/// one device has nobody to message. An App Store reviewer in that position
/// files it under guideline 2.1, App Completeness, which is the single largest
/// bucket of rejections, and they are not wrong: they could not evaluate it.
///
/// A note to self makes the app usable on one device, but a reviewer cannot
/// tell a real round trip from a local notepad. This can: it is a second party,
/// somewhere else, that replies. Point the review notes at a phrase, run this,
/// and the reviewer has a conversation.
///
/// # Why it is here and not in the protocol repository
///
/// It is a client. It uses the same engine, the same rendezvous and the same
/// mailbox client the application uses, so there is no second implementation of
/// the handshake to drift out of step. The mailbox server learns nothing from
/// it that it does not learn from any other member.
///
/// # Why it is not the store answer on its own
///
/// It has to be running while somebody is reviewing, and the phrase is a door
/// anybody who reads the review notes can walk through. Use a phrase minted for
/// one submission, run this for that window, and stop it afterwards.
///
/// # Running it
///
///   dart run tool/review_peer.dart "the phrase from the review notes"
///
/// It needs `librotelyx_mobile.so` on the loader path:
///
///   LD_LIBRARY_PATH=build/native dart run tool/review_peer.dart "..."
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rotelyx_chat/rotelyx/engine/api.dart';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_config.dart';

/// The mailbox, spoken directly rather than through `MailboxClient`.
///
/// Not a second implementation of anything that matters. The client in `lib`
/// reaches `push.dart` for the one method that registers a wake token, and that
/// reaches a Flutter method channel, which cannot exist in a process with no
/// Flutter in it. The wire is four frames wide and none of them are the wake
/// one, so this is the whole protocol this peer needs.
class _Mailbox {
  _Mailbox(this.url);

  final String url;
  WebSocket? _socket;

  final _envelopes = StreamController<String>.broadcast();
  Stream<String> get envelopes => _envelopes.stream;

  Future<void> connect() async {
    final socket = await WebSocket.connect(url)
        .timeout(const Duration(seconds: 15));
    _socket = socket;
    socket.listen(
      (dynamic frame) {
        if (frame is! String) return;
        final Map<String, dynamic> decoded;
        try {
          decoded = jsonDecode(frame) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        if (decoded['op'] == 'envelope' && decoded['envelope'] is String) {
          _envelopes.add(decoded['envelope'] as String);
        } else if (decoded['op'] == 'error') {
          stderr.writeln('mailbox refused a frame: ${decoded['message']}');
        }
      },
      onError: (Object e) => stderr.writeln('mailbox: $e'),
      onDone: () => stderr.writeln('mailbox closed the connection'),
      cancelOnError: false,
    );
  }

  void _send(Map<String, Object?> frame) => _socket?.add(jsonEncode(frame));

  void deposit(String envelope) =>
      _send({'op': 'deposit', 'envelope': envelope});

  void subscribe(List<String> tags) =>
      _send({'op': 'subscribe', 'tags': tags});

  Future<void> close() async => _socket?.close();
}

/// What it says back. Deliberately dull: it is here to prove delivery, not to
/// pretend to be a person.
String reply(String heard) =>
    'Received: "$heard". This reply travelled to the mailbox and back, so '
    'delivery is working in both directions.';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/review_peer.dart "<phrase>"');
    stderr.writeln('the phrase is whatever the review notes tell the reviewer '
        'to type.');
    exit(2);
  }

  final phrase = args.first;
  if (phrase.length < 8) {
    stderr.writeln('that phrase is shorter than the application will accept.');
    exit(2);
  }

  final RotelyxEngine engine;
  try {
    engine = createEngine();
  } on Object catch (e) {
    stderr.writeln('the engine did not load: $e');
    stderr.writeln('try: LD_LIBRARY_PATH=build/native dart run '
        'tool/review_peer.dart "..."');
    exit(1);
  }

  final session = engine.newSession('Rotelyx');
  session.found();

  final meeting = engine.rendezvousTag(phrase);
  final mailbox = _Mailbox(rotelyxConfig.mailbox);

  // Nothing is written down. This process is a conversation and no more, which
  // is also why stopping it leaves nothing behind to clean up.
  var joined = false;

  void depositRendezvous(Map<String, Object?> payload) {
    final body = base64Encode(utf8.encode(jsonEncode(payload)));
    mailbox.deposit(engine.sealUnder(meeting, body));
  }

  void resubscribe() {
    try {
      mailbox.subscribe(session.myPollingTags(rotelyxConfig.lookback));
    } on Object {
      // No tag key until somebody joins. Nothing to listen to yet.
    }
  }

  /// Somebody knocked. Let them in, exactly the way the application does.
  void admit(Map<String, dynamic> msg) {
    try {
      final invitation = session.invite(msg['keyPackage'] as String);

      depositRendezvous({
        't': 'welcome',
        'name': 'Rotelyx',
        'welcome': invitation.welcome,
        'ratchetTree': invitation.ratchetTree,
        'pqCiphertext':
            session.encapsulateTo(msg['hybridPublicKey'] as String),
      });
      depositRendezvous({'t': 'commit', 'commit': session.commitPq()});

      joined = true;
      resubscribe();
      stdout.writeln('joined by ${msg['name'] ?? 'someone'}. '
          'safety number: ${session.safetyNumber()}');
      stdout.writeln('read that number back to whoever is testing: if it '
          'matches on their screen, nobody is in between.');
    } on Object catch (e) {
      stderr.writeln('could not admit them: $e');
    }
  }

  void onEnvelope(String incoming) {
    // Meeting traffic first, the same order the application uses: the
    // post-quantum commit arrives under the meeting tag after the conversation
    // already exists, and deciding on state would drop it.
    try {
      final payload = engine.openUnder(incoming, meeting);
      final msg = jsonDecode(utf8.decode(base64Decode(payload)))
          as Map<String, dynamic>;
      if (msg['t'] == 'hello') admit(msg);
      return;
    } on Object {
      // Not meeting traffic. Fall through.
    }

    if (!joined) return;

    try {
      final plaintext =
          session.receive(session.openMine(incoming, rotelyxConfig.lookback));

      if (plaintext == null) {
        // A commit. The epoch moved and the tags moved with it.
        resubscribe();
        return;
      }

      // Control messages travel as application messages here too. Answering a
      // read receipt with a sentence would be nonsense.
      if (plaintext.contains('\x1f')) return;

      stdout.writeln('heard: $plaintext');
      final answer = reply(plaintext);
      for (final envelope in session.sealForGroup(session.send(answer))) {
        mailbox.deposit(envelope);
      }
      stdout.writeln('replied.');
    } on Object {
      // Not addressed to this member in this window. Ignoring is correct:
      // reacting to it would itself be a signal.
    }
  }

  mailbox.envelopes.listen(onEnvelope);

  try {
    await mailbox.connect();
  } on Object catch (e) {
    stderr.writeln('could not reach the mailbox at '
        '${Uri.parse(rotelyxConfig.mailbox).host}: $e');
    exit(1);
  }

  mailbox.subscribe([meeting]);

  stdout.writeln('waiting at the phrase, on ${Uri.parse(rotelyxConfig.mailbox).host}.');
  stdout.writeln('tell the reviewer to choose On a call, type the phrase, and '
      'send anything.');
  stdout.writeln('stop with ctrl+c. nothing is written to disk.');

  // The tags are derived from the hour, so they have to be recomputed as it
  // rolls over or the conversation goes quiet at the top of the hour and stays
  // quiet, which reads as the other side having left.
  Timer.periodic(const Duration(minutes: 1), (_) {
    if (joined) resubscribe();
  });

  await ProcessSignal.sigint.watch().first;
  stdout.writeln('\nstopping.');
  await mailbox.close();
  session.dispose();
  exit(0);
}
