/// When each side's clock starts.
///
/// This is the property the feature lives or dies on, and it is not "the text
/// round trips". A self destructing message that burns on one device and stays
/// on the other is worse than one that never burned at all, because the person
/// who set the timer watched their copy go and believes both are gone.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/burn_clock.dart';
import 'package:rotelyx_chat/rotelyx/ephemeral.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

/// A message as it sits in a conversation.
StoredMessage msg(String text, {required bool mine, DateTime? burnAt}) =>
    StoredMessage(
        text: text, mine: mine, at: DateTime(2026, 1, 1), burnAt: burnAt);

void main() {
  test('reading starts the clock on what they sent, and nothing else', () {
    final theirs = Ephemeral.wrap(seconds: 60, body: 'gone in a minute');
    final ours = Ephemeral.wrap(seconds: 60, body: 'ours, not read yet');

    final started = onRead([
      msg(theirs.encode(), mine: false),
      msg(ours.encode(), mine: true),
      msg('an ordinary message', mine: false),
    ]);

    expect(started.changed, isTrue);
    expect(started.messages[0].burnAt, isNotNull,
        reason: 'we have just read theirs');
    expect(started.messages[1].burnAt, isNull,
        reason: 'ours waits for them to read it, or the two clocks disagree');
    expect(started.messages[2].burnAt, isNull,
        reason: 'a message with no timer never gains one');

    expect(started.acknowledge, [theirs.id]);
  });

  test('the sender starts on the acknowledgement and not before', () {
    final sent = Ephemeral.wrap(seconds: 300, body: 'read this');
    final messages = [msg(sent.encode(), mine: true)];

    // Nothing has come back yet.
    expect(onAcknowledged(messages, {}).changed, isFalse);
    expect(onAcknowledged(messages, {'0123456789abcdef'}).changed, isFalse,
        reason: 'an identifier for some other message must not start ours');

    final started = onAcknowledged(messages, {sent.id});
    expect(started.changed, isTrue);
    expect(started.messages[0].burnAt, isNotNull);
    expect(started.messages[0].seen, isTrue,
        reason: 'read is read, so the tick and the flame agree');
  });

  test('an acknowledgement is not a read receipt for the whole conversation',
      () {
    final timed = Ephemeral.wrap(seconds: 60, body: 'this one expires');
    final plain = msg('this one does not', mine: true);

    final started =
        onAcknowledged([msg(timed.encode(), mine: true), plain], {timed.id});

    expect(started.messages[1].seen, isFalse,
        reason: 'it names one message, so it may only speak for that one');
  });

  test('an acknowledgement never starts a clock on their own copy', () {
    // Their copy is theirs to run. Applying an identifier we received to a
    // message we received would restart a clock that is already going.
    final theirs = Ephemeral.wrap(seconds: 60, body: 'from them');
    final already = DateTime(2026, 1, 1, 12);

    final started = onAcknowledged(
        [msg(theirs.encode(), mine: false, burnAt: already)], {theirs.id});

    expect(started.changed, isFalse);
    expect(started.messages[0].burnAt, already);
  });

  test('reading twice does not restart a clock or acknowledge twice', () {
    final theirs = Ephemeral.wrap(seconds: 60, body: 'once is enough');
    final first = onRead([msg(theirs.encode(), mine: false)],
        now: DateTime(2026, 1, 1, 12));

    final again = onRead(first.messages, now: DateTime(2026, 1, 1, 13));

    expect(again.changed, isFalse);
    expect(again.acknowledge, isEmpty,
        reason: 'a second envelope per open is a deposit an operator counts');
    expect(again.messages[0].burnAt, first.messages[0].burnAt,
        reason: 'reopening a conversation must not extend the timer');
  });

  test('the deadline is the duration the sender chose', () {
    final now = DateTime(2026, 1, 1, 12);
    final theirs = Ephemeral.wrap(seconds: 3600, body: 'an hour');

    final started = onRead([msg(theirs.encode(), mine: false)], now: now);
    expect(started.messages[0].burnAt, now.add(const Duration(hours: 1)));
  });

  test('a message from a build without identifiers still burns here', () {
    // It cannot be acknowledged, so the sender's copy will wait. Ours going is
    // still the right behaviour: the timer was set and we have read it.
    const legacy = 'rx-burn\x1f60\x1fno identifier in this one';
    final started = onRead([msg(legacy, mine: false)]);

    expect(started.messages[0].burnAt, isNotNull);
    expect(started.acknowledge, isEmpty);
  });

  test('a note to yourself burns, because you are the one reading it', () {
    // The ordinary rule gives the wrong answer here. A message of ours starts
    // expiring when they read it, and in a conversation with yourself there is
    // no they: both members are this device. Without the exception a note set
    // to burn sits with a dash where the countdown should be, forever, which
    // is indistinguishable from the feature not working.
    final messages = [
      StoredMessage(
        text: Ephemeral.wrap(seconds: 10, body: 'a note to myself').encode(),
        mine: true,
        at: DateTime.now(),
      ),
    ];

    final ordinary = onRead(messages);
    expect(ordinary.changed, isFalse,
        reason: 'in a normal conversation our own message waits for them');

    final self = onRead(messages, ownMessagesToo: true);
    expect(self.changed, isTrue);
    expect(self.messages.first.burnAt, isNotNull);
  });

  test('and the exception does not leak into an ordinary conversation', () {
    // The flag is the whole risk: switched on somewhere it does not belong, it
    // would start every sender's clock the moment they sent, which is the
    // property this design exists to avoid.
    final theirs = StoredMessage(
      text: Ephemeral.wrap(seconds: 10, body: 'theirs').encode(),
      mine: false,
      at: DateTime.now(),
    );
    final mine = StoredMessage(
      text: Ephemeral.wrap(seconds: 10, body: 'mine').encode(),
      mine: true,
      at: DateTime.now(),
    );

    final read = onRead([theirs, mine]);
    expect(read.messages[0].burnAt, isNotNull, reason: 'theirs starts');
    expect(read.messages[1].burnAt, isNull, reason: 'ours waits for them');
  });
}
