/// Does the mailbox hold an envelope for somebody who is not there yet.
///
/// **Not part of the suite.** It talks to the live server.
///
///   LD_LIBRARY_PATH=build/native flutter test test/live_store_and_forward_probe.dart
///
/// `live_mailbox_probe.dart` proves the easy half: both ends connected at once.
/// This proves the half that matters when a phone has been asleep. The envelope
/// is deposited with **nobody listening at all**, the depositing socket is then
/// closed, and only afterwards does a fresh client connect and ask. That is
/// exactly the shape of a message sent to a locked phone.
///
/// If this passes, an undelivered message is the client having stopped asking.
/// If it fails, it is the mailbox not keeping what it took.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/mailbox_client.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_config.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_wasm.dart';

void main() {
  test('an envelope left for nobody is still there when somebody asks',
      () async {
    final url = rotelyxConfig.mailbox;

    // A tag nothing else uses, different on every run so a previous run's
    // leftovers cannot make this one look like it worked.
    final unique = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final tag = (unique * 8).substring(0, 64);

    // ---- deposit, with nobody subscribed anywhere ----
    final sender = MailboxClient(url);
    sender.errors.listen((e) => printOnFailure('sender: $e'));
    await sender.connect();

    sender.deposit(RotelyxWasm.sealUnder(tag, 'aGVsbG8='));

    final accepted = await sender.accepted.first
        .timeout(const Duration(seconds: 15), onTimeout: () => -1);
    expect(accepted, isNot(-1), reason: 'the mailbox never took the envelope');

    // The depositing socket goes away entirely, so nothing about it can be
    // what keeps the envelope alive.
    await sender.close();

    // ---- much later, a phone wakes up and asks ----
    await Future<void>.delayed(const Duration(seconds: 3));

    final collector = MailboxClient(url);
    collector.errors.listen((e) => printOnFailure('collector: $e'));

    String? got;
    collector.envelopes.listen((e) => got ??= e.envelope);

    await collector.connect();
    collector.subscribe([tag]);

    final waiting = await collector.subscribed.first
        .timeout(const Duration(seconds: 15), onTimeout: () => -1);

    expect(waiting, isNot(-1), reason: 'the mailbox never confirmed a subscribe');
    expect(waiting, greaterThan(0),
        reason: 'the mailbox said nothing was waiting under a tag it had just '
            'accepted an envelope for, so it is not keeping what it takes');

    // And it actually hands it over, not merely counts it.
    for (var i = 0; i < 40 && got == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(got, isNotNull,
        reason: 'the mailbox counted it as waiting and never delivered it');

    await collector.close();
  }, timeout: const Timeout(Duration(seconds: 120)));
}
