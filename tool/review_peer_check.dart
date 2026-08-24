/// Checks that `review_peer.dart` actually answers, before anybody submits.
///
/// Run the peer with a phrase, then run this with the same phrase. It joins the
/// way the application joins, says something, and waits for the reply. If it
/// prints a reply, a reviewer holding one device will get one too.
///
///   LD_LIBRARY_PATH=build/native dart run tool/review_peer.dart "the phrase" &
///   LD_LIBRARY_PATH=build/native dart run tool/review_peer_check.dart "the phrase"
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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


Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/review_peer_check.dart "<phrase>"');
    exit(2);
  }

  final engine = createEngine();
  final session = engine.newSession('Reviewer');
  final meeting = engine.rendezvousTag(args.first);
  final mailbox = _Mailbox(rotelyxConfig.mailbox);

  final replied = Completer<String>();
  var joined = false;

  void depositRendezvous(Map<String, Object?> payload) {
    mailbox.deposit(engine.sealUnder(
        meeting, base64Encode(utf8.encode(jsonEncode(payload)))));
  }

  mailbox.envelopes.listen((incoming) {
    // Meeting traffic first, the order the application uses.
    try {
      final msg = jsonDecode(utf8.decode(base64Decode(
              engine.openUnder(incoming, meeting)))) as Map<String, dynamic>;

      switch (msg['t']) {
        case 'welcome' when !joined:
          session.join(msg['welcome'] as String, msg['ratchetTree'] as String);
          final pq = msg['pqCiphertext'];
          if (pq is String) session.openPq(pq);
          joined = true;
          stdout.writeln('joined. safety number: ${session.safetyNumber()}');

        case 'commit':
          session.receive(msg['commit'] as String);
          mailbox.subscribe(session.myPollingTags(rotelyxConfig.lookback));

          // Only now is the group settled enough to speak into.
          const said = 'hello from a reviewer with one device';
          stdout.writeln('saying: $said');
          for (final e in session.sealForGroup(session.send(said))) {
            mailbox.deposit(e);
          }
      }
      return;
    } on Object {
      // Not meeting traffic.
    }

    if (!joined) return;
    try {
      final heard = session
          .receive(session.openMine(incoming, rotelyxConfig.lookback));
      if (heard != null && !replied.isCompleted) replied.complete(heard);
    } on Object {
      // Not for us in this window.
    }
  });

  await mailbox.connect();
  mailbox.subscribe([meeting]);

  depositRendezvous({
    't': 'hello',
    'name': 'Reviewer',
    'keyPackage': session.keyPackage(),
    'hybridPublicKey': session.hybridPublicKey(),
  });
  stdout.writeln('knocking at the phrase...');

  final answer = await replied.future
      .timeout(const Duration(seconds: 40), onTimeout: () => '');

  await mailbox.close();
  session.dispose();

  if (answer.isEmpty) {
    stderr.writeln('no reply in forty seconds. the peer is not answering.');
    exit(1);
  }

  stdout.writeln('reply: $answer');
  stdout.writeln('the round trip works.');
  exit(0);
}
