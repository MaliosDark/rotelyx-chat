/// Messages that destroy themselves.
///
/// The property worth pinning down is not that the text round trips, it is
/// *when the clock starts*. A message that begins expiring in a mailbox can be
/// destroyed by keeping somebody offline, and somebody who set a one minute
/// timer meant a minute after it was read.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/ephemeral.dart';
import 'package:rotelyx_chat/rotelyx/quoted.dart';

void main() {
  test('a timed message round trips', () {
    const e = Ephemeral(seconds: 60, body: 'this goes in a minute');
    final back = Ephemeral.decode(e.encode());

    expect(back, isNotNull);
    expect(back!.seconds, 60);
    expect(back.body, 'this goes in a minute');
  });

  test('an ordinary message is untouched', () {
    expect(Ephemeral.decode('just a message'), isNull);
    expect(Ephemeral.isEphemeral('just a message'), isFalse);
    expect(Ephemeral.plain('just a message'), 'just a message');
  });

  test('the timer wraps a reply rather than replacing it', () {
    // A reply that expires has to be both, and the timer comes off first so
    // what is underneath is an ordinary reply.
    final reply =
        const Quoted(author: 'Ana', excerpt: 'the question', reply: 'the answer')
            .encode();
    final timed = Ephemeral(seconds: 300, body: reply).encode();

    final unwrapped = Ephemeral.decode(timed)!;
    expect(unwrapped.seconds, 300);
    expect(Quoted.decode(unwrapped.body)!.reply, 'the answer');

    // And what one line shows is the reply, not a marker.
    expect(Quoted.plain(Ephemeral.plain(timed)), 'the answer');
  });

  test('a malformed timer is shown rather than burnt or lost', () {
    // A build that disagrees about the format should not silently destroy
    // somebody's message, and should not refuse to show it either.
    expect(Ephemeral.decode('rx-burn\x1fnotanumber\x1fhello'), isNull);
    expect(Ephemeral.decode('rx-burn\x1f0\x1fhello'), isNull);
    expect(Ephemeral.decode('rx-burn\x1f-5\x1fhello'), isNull);
    expect(Ephemeral.decode('rx-burn\x1f60'), isNull);
  });

  test('a body containing a separator is not truncated', () {
    final encoded = const Ephemeral(seconds: 10, body: 'one\x1ftwo').encode();
    expect(Ephemeral.decode(encoded)!.body, 'one\x1ftwo');
  });

  test('a wrapped message carries an identifier both copies share', () {
    final e = Ephemeral.wrap(seconds: 60, body: 'hello');
    expect(e.id, hasLength(16));

    // The identifier travels in the body, which is what makes it the same
    // value on the other device. A timestamp would not be: each device stamps
    // a message with its own clock.
    final back = Ephemeral.decode(e.encode())!;
    expect(back.id, e.id);
    expect(back.body, 'hello');
  });

  test('two messages never share an identifier', () {
    final ids = {
      for (var i = 0; i < 500; i++)
        Ephemeral.wrap(seconds: 10, body: 'same text every time').id,
    };
    expect(ids.length, 500,
        reason: 'a collision starts a clock on the wrong message');
  });

  test('a message from a build without identifiers still reads', () {
    final back = Ephemeral.decode('rx-burn\x1f60\x1fhello')!;
    expect(back.seconds, 60);
    expect(back.body, 'hello');
    expect(back.id, isEmpty);
  });

  test('an identified body containing a separator is not truncated', () {
    final encoded = Ephemeral.wrap(seconds: 10, body: 'one\x1ftwo').encode();
    final back = Ephemeral.decode(encoded)!;
    expect(back.body, 'one\x1ftwo');
    expect(back.id, hasLength(16));
  });

  test('every offered duration has a label and they are all distinct', () {
    final labels = burnChoices.map(burnLabel).toList();
    expect(labels.toSet().length, burnChoices.length,
        reason: 'two choices reading the same is a menu nobody can use');
    expect(labels, ['10s', '1m', '5m', '1h', '1d', '1w']);
  });

  test('the durations are ordered and sane', () {
    for (var i = 1; i < burnChoices.length; i++) {
      expect(burnChoices[i], greaterThan(burnChoices[i - 1]));
    }
    expect(burnChoices.first, greaterThanOrEqualTo(5),
        reason: 'anything shorter is gone before it can be read');
  });
}
