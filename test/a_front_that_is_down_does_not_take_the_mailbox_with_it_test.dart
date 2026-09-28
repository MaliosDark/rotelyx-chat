/// A front that will not open must not cost this device its mailbox.
///
/// # What this guards
///
/// The front is an optimisation: it saves connections and stops the mailbox
/// grouping one device's conversations. Neither is worth failing to deliver a
/// message over, so a front that refuses falls through to the mailbox itself,
/// which is what every build did before fronts existed.
///
/// The fallback existed and did not work. Whether a client spoke through a
/// front was read off its configuration, which never changes, so after falling
/// back it went on looking for a front session: `isOpen` answered false with a
/// live socket in hand, and every send failed with "the front session is not
/// open" while that socket sat unused. The symptom reached a phone as a
/// conversation on a mailbox that could not be subscribed to, with the mailbox
/// itself perfectly healthy.
///
/// So this connects a client whose front is not there at all, and asks the one
/// question that matters: did anything actually reach the mailbox.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/mailbox_client.dart';

void main() {
  test('a front that will not open leaves a working mailbox connection',
      () async {
    // A mailbox that answers a subscribe, as the real one does.
    final received = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.transform(WebSocketTransformer()).listen((socket) {
      socket.listen((Object? data) {
        final text = data as String;
        received.add(text);
        final frame = jsonDecode(text) as Map<String, dynamic>;
        if (frame['op'] == 'subscribe') {
          socket.add(jsonEncode({'op': 'ready', 'waiting': 0}));
        }
      });
    });

    // A front on a port that was bound just long enough to be sure nobody is
    // listening on it.
    final vacated = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = vacated.port;
    await vacated.close();

    final client = MailboxClient(
      'ws://127.0.0.1:${server.port}/mailbox',
      frontUrl: 'ws://127.0.0.1:$deadPort',
      // Never used: the connection to the front fails before anything is
      // sealed to this.
      frontKey: 'the front is never reached',
    );

    await client.connect();
    expect(client.isOpen, isTrue,
        reason: 'the socket it fell back to is the connection it has');

    final ready = client.subscribed.first;
    client.subscribe(['aa' * 32]);

    expect(await ready.timeout(const Duration(seconds: 5)), 0,
        reason: 'the mailbox answered the subscribe, so it arrived');
    expect(received.length, 1);
    expect(received.single, contains('subscribe'));

    await client.close();
    await server.close(force: true);
  });
}
