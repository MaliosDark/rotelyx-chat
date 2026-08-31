/// Every frame this client sends is one the mailbox accepts.
///
/// # Why this file exists
///
/// The browser client sent `{"op":"fanout",...}` for months after the server
/// stopped accepting it. The server answered `malformed request`, the deposit
/// never happened, and nothing on the page said so: a group message simply did
/// not arrive. It survived because the tests drove conversations of two, where
/// that path is never taken, and because a refused deposit produces no error
/// anybody sees.
///
/// The two sides live in different repositories, so nothing types the join. A
/// list is the weaker tool and it is the one available: it fails when this
/// client learns a new frame, which forces somebody to check the server accepts
/// it, rather than discovering it from a conversation that quietly went
/// nowhere.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What `Request` in `rotelyx-mailbox-server` deserialises, and what each is
/// for. Sorted, and every entry earns its place by naming the reply it expects.
const accepted = <String, String>{
  'deposit': 'one sealed envelope. Answered with `stored`, or `overquota` when '
      'the allowance is spent and the envelope was not kept',
  'subscribe': 'listen on these tags, and hand over what is already waiting. '
      'Answered with `ready`',
  'unsubscribe': 'stop listening. Answered with `dropped`',
  'collected': 'these arrived and can be let go, by digest. Delivery peeks and '
      'removal waits for this, so a client that never sends it leaves every '
      'envelope until the TTL and fills the tag',
  'auth': 'present a capability token. Answered with `tier`',
  'authBlind': 'present a blindly issued one',
  'registerWake': 'be woken on the schedule. Answered with `wakeRegistered`',
  'revokeWake': 'stop being woken',
};

void main() {
  test('this client sends no frame the mailbox would refuse', () {
    final root = Directory.current;
    // Both quote styles. Dart writes single quotes by convention and nothing
    // enforces it, and a guard that only reads the convention is a guard the
    // next author walks past without knowing.
    final sending = RegExp(r'''["']op["']\s*:\s*["']([A-Za-z]+)["']''');
    final offenders = <String>[];

    for (final entity in Directory('${root.path}/lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final relative = entity.path.replaceFirst('${root.path}/', '');
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        // Not comments. This file documents the frames the **server** sends,
        // in the same shape, and reading those as things this client sends
        // made the guard shout about its own documentation. A guard that cries
        // on correct code is one somebody eventually deletes.
        if (lines[i].trimLeft().startsWith('//')) continue;

        for (final m in sending.allMatches(lines[i])) {
          final op = m.group(1)!;
          if (accepted.containsKey(op)) continue;
          offenders.add('$relative:${i + 1} → $op');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These send a frame the mailbox does not accept. The server '
          'answers `malformed request` and does nothing, which from here looks '
          'exactly like a message that went through. If the server really does '
          'take it, add it to `accepted` with the reply it expects; if it does '
          'not, this test has just caught what took months to find last time.',
    );
  });

  test('the acknowledgement is one of them, and is actually sent', () {
    // Not merely spelled correctly: present. Every envelope this client keeps
    // has to be released, or the recipient's tag fills at 256 and the server
    // starts refusing deposits to them.
    final client =
        File('${Directory.current.path}/lib/rotelyx/mailbox_client.dart')
            .readAsStringSync();

    expect(client, contains("'op': 'collected'"),
        reason: 'without this the mailbox holds everything for seven days and '
            'the tag eventually fills, which loses messages silently');

    final service =
        File('${Directory.current.path}/lib/rotelyx/rotelyx_service.dart')
            .readAsStringSync();

    expect(service, contains('_acknowledge('),
        reason: 'the client can send it and something has to call it: an '
            'unused acknowledgement is the same as none');
  });

  test('a refusal reaches somebody who is in a conversation', () {
    // The first version of the quota fix put the message on the mailbox's
    // error channel, and the service acted on that channel only while **not**
    // joined: joined, it did nothing at all. So the refusal was reported into
    // a listener that dropped it in exactly the state where deposits happen.
    //
    // What the fix needs is that a joined client both keeps working and says
    // something, which is a different thing from failing the conversation.
    final service =
        File('${Directory.current.path}/lib/rotelyx/rotelyx_service.dart')
            .readAsStringSync();

    expect(service, contains('_notices.add('),
        reason: 'a refusal that arrives mid-conversation has to go somewhere '
            'the screen is listening, or it is the same as not reporting it');

    expect(service, contains('Stream<String> get notices'),
        reason: 'and that somewhere has to be reachable from the UI');

    final chat = File('${Directory.current.path}/lib/ui/screens/chat.dart')
        .readAsStringSync();

    expect(chat, contains('rotelyx.notices.listen'),
        reason: 'a channel nobody subscribes to is a channel that discards, '
            'which is what this test exists to stop happening twice');
  });

  test('every path that opens an envelope also releases it', () {
    // The first version of the acknowledgement covered one path of three. A
    // conversation message released its envelope; a handshake at the meeting
    // tag and a note to self did not, so those two went on sitting until the
    // TTL. Nothing failed, because nothing checks a mailbox for what it is
    // still holding.
    //
    // Counting is crude and it is what can be counted: an envelope is opened in
    // exactly three places in this file, and each has to release what it
    // consumed. If a fourth appears, this fails and somebody decides.
    final service =
        File('${Directory.current.path}/lib/rotelyx/rotelyx_service.dart')
            .readAsStringSync();

    // `open` is on the list because the ABI has `session.open` and this
    // interface does not yet: if it ever arrives, it opens envelopes too and
    // has to release them. Naming only what exists today is how a guard ends
    // up watching the wrong three things.
    final opens = RegExp(r'\.(open|openMine|openUnder)\(').allMatches(service).length;
    final releases = RegExp(r'_acknowledge\(').allMatches(service).length;

    expect(opens, 3,
        reason: 'an envelope is opened somewhere new. Whatever it is, decide '
            'whether it consumes the envelope, and release it if it does');

    // Three call sites plus the declaration and the doc reference to it.
    expect(releases, greaterThanOrEqualTo(opens + 1),
        reason: 'each of the $opens paths that opens an envelope has to '
            'release it, or the mailbox holds it for seven days and the tag '
            'fills at 256, which loses messages');
  });
}
