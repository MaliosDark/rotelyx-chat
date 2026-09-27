/// A device can still send while its mailboxes are opening.
///
/// # The defect this exists for
///
/// "no mailbox in the constellation is holding that address", on an iPhone,
/// for a conversation the other end was holding perfectly well.
///
/// A peer object is made for every mailbox in the constellation and they are
/// opened together, and one refusing is not a failure: the constellation is
/// usable as long as one answered. An earlier change made the routing take
/// only the peers that had answered, so that frames would stop being handed
/// to a mailbox that never connected and complaining about it.
///
/// That list is also what `deposit` sends to, and an empty one is refused
/// outright with the sentence above. So a device whose peers had not finished
/// opening could not send at all: one complaint on the screen became a
/// conversation that did not work.
///
/// The routing now prefers the peers that answered and falls back to the ones
/// that should have, so the list is never empty while the constellation has
/// members. A frame handed to a shut peer does not go and says so from the one
/// place that knows why.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/mailbox_client.dart';

void main() {
  /// Three mailboxes that cannot be reached, which is the same shape as three
  /// that have not finished opening.
  const directory = '{"version":1,"replicas":2,"mailboxes":['
      '{"id":"one","url":"wss://one.invalid/mailbox"},'
      '{"id":"two","url":"wss://two.invalid/mailbox"},'
      '{"id":"three","url":"wss://three.invalid/mailbox"}]}';

  test('a deposit is not refused for want of a mailbox that answered',
      () async {
    final client =
        MailboxClient('wss://one.invalid/mailbox', constellation: directory);
    addTearDown(client.close);

    final said = <String>[];
    final listening = client.errors.listen(said.add);
    addTearDown(listening.cancel);

    // Opening fails, and that is the state under test: the peers exist and
    // none of them answered.
    try {
      await client.connect();
    } on Object {
      // Expected. `connect` throws when nothing answered, and the peers it
      // made are still there, which is exactly the window a real device is in
      // while its connections are still being established.
    }
    said.clear();

    // Any address. What matters is that it is routed somewhere rather than
    // nowhere; which of the three is the placement's business.
    expect(
      client.holdersForTest('a' * 64),
      greaterThan(0),
      reason: 'the constellation has three mailboxes; routing to none of them '
          'because none has answered yet is a conversation that cannot send '
          'rather than a mailbox that is missing',
    );
  });
}
