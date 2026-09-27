/// What a client says when it is asked to send before it is connected.
///
/// # The defect this exists for
///
/// "tried to send while the front session was closed", on the screen, while
/// the application was starting up and nothing was wrong.
///
/// A front session is opened after the client exists, so there is a window in
/// which nothing can be sent yet. A message that misses it is worth saying so:
/// somebody pressed send and it did not go. A wake ticket that misses it is
/// not. Tickets are left again on every subscription and subscribing happens
/// on every reconnection, so one that misses the window is left a moment
/// later, and reporting it was a line of alarming prose about something
/// nobody asked for and nothing had lost.
///
/// The window got much wider when tickets started being left for the hours
/// ahead as well as this one, which is why it began showing up.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/mailbox_client.dart';

void main() {
  /// A client that has not connected: a front is configured, so everything it
  /// sends goes through a session that does not exist yet.
  MailboxClient unconnected() => MailboxClient(
        'wss://example.invalid/mailbox',
        frontUrl: 'wss://example.invalid',
        frontKey: 'not-a-key',
      );

  test('a wake ticket that cannot be left says nothing', () async {
    final client = unconnected();
    addTearDown(client.close);

    final said = <String>[];
    final listening = client.errors.listen(said.add);
    addTearDown(listening.cancel);

    client.leaveTickets({'a' * 64: 'a-sealed-ticket'});
    await Future<void>.delayed(Duration.zero);

    expect(said, isEmpty,
        reason: 'a ticket is left again on the next subscription, so failing '
            'to leave one now is not worth a word on somebody screen');
  });

  test('a deposit that cannot be sent still says so', () async {
    final client = unconnected();
    addTearDown(client.close);

    final said = <String>[];
    final listening = client.errors.listen(said.add);
    addTearDown(listening.cancel);

    client.deposit('an-envelope');
    await Future<void>.delayed(Duration.zero);

    expect(said, isNotEmpty,
        reason: 'somebody pressed send and it did not go out, which is the '
            'one case that has to be reported');
    // And it says which mailbox and what was being sent, because the same
    // sentence for every operation and every member of a constellation is a
    // report nobody can act on.
    expect(said.first, contains('deposit'));
    expect(said.first, contains('example.invalid'));
  });
}
