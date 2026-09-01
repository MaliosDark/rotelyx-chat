/// Does an envelope cross the real mailbox through `MailboxClient`.
///
/// **Not part of the suite.** It talks to a live server, so it fails when the
/// network is down and that is not a defect in this application. Run it by name
/// when a conversation pairs and then stays silent:
///
///   LD_LIBRARY_PATH=build/native flutter test test/live_mailbox_probe.dart
///
/// `tool/review_peer.dart` proves the engine, the handshake and the server, and
/// says nothing about this client because it speaks the mailbox directly. The
/// application uses this client for everything it sends and receives, so this is
/// the piece that harness cannot reach.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/mailbox_client.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_config.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_wasm.dart';

void main() {
  test('an envelope goes out and comes back through MailboxClient', () async {
    final url = rotelyxConfig.mailbox;
    final tag = List.filled(32, '7a').join();

    final collector = MailboxClient(url);
    collector.errors.listen((e) => printOnFailure('collector: $e'));

    final arrived = Completer<String>();
    collector.envelopes.listen((e) {
      if (!arrived.isCompleted) arrived.complete(e.envelope);
    });

    await collector.connect();
    collector.subscribe([tag]);

    final waiting = await collector.subscribed.first
        .timeout(const Duration(seconds: 15), onTimeout: () => -1);
    expect(waiting, isNot(-1), reason: 'the mailbox never confirmed a subscribe');

    final sender = MailboxClient(url);
    sender.errors.listen((e) => printOnFailure('sender: $e'));
    await sender.connect();

    sender.deposit(RotelyxWasm.sealUnder(tag, 'aGVsbG8='));

    final accepted = await sender.accepted.first
        .timeout(const Duration(seconds: 15), onTimeout: () => -1);
    expect(accepted, isNot(-1),
        reason: 'the mailbox never acknowledged the deposit');

    final got = await arrived.future
        .timeout(const Duration(seconds: 20), onTimeout: () => '');
    expect(got, isNotEmpty,
        reason: 'the envelope was accepted and never came back, so this client '
            'deposits and does not receive');

    await collector.close();
    await sender.close();
  }, timeout: const Timeout(Duration(seconds: 90)));
}
