/// A read tick in a group, which has to wait for everybody.
///
/// # The defect this covers
///
/// The tick is only honest once every other member has said they read it, and
/// the service was written that way: it collects names and shows the tick when
/// that list reaches the number of other members.
///
/// Which name it collected was the conversation's, not the sender's.
/// `conversationName` for three people is a single string like "Alice and 2
/// others", so every member's receipt arrived under the same name, the second
/// was skipped as a repeat, and the list never grew past one. **In a group the
/// tick could not appear at all.**
///
/// It worked for two people, which is why nothing showed it: with one other
/// member the name is that member's, and one receipt is all the tick needs.
///
/// MLS authenticates the sending leaf and always has. `rotelyx-crypto` carries
/// it, the wasm layer dropped it on the way out, and the service reached for the
/// only name it had left.
///
/// # Why these drive a function rather than a conversation
///
/// `memberCount` comes from a live MLS session, so exercising a group of three
/// through the service means founding a group of three. No test did, which is
/// how the group case stayed wrong. `RotelyxService.readBy` takes the count as
/// a number, so a group of eight can be asked about without one existing.
///
/// The other half, **which name gets recorded**, cannot be asked of a function
/// that is handed the name. That one lives in `note_to_self_service_test.dart`,
/// with the rest of the tests that drive the service: two files owning the same
/// global store at once fight over it on disk, and this suite runs them
/// together.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_service.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

void main() {
  final sent = DateTime(2026, 5, 6, 10, 30);
  final later = sent.add(const Duration(seconds: 1));

  StoredMessage ours() => StoredMessage(
        text: 'for the group',
        mine: true,
        at: sent,
      );

  test('a group of three waits for both readers', () {
    var m = ours();

    m = RotelyxService.readBy(m, 'Beto', later, 2)!;
    expect(m.seenBy, ['Beto']);
    expect(m.seen, isFalse,
        reason: 'one of two readers is not everybody, and a tick that appears '
            'then says something the sender cannot rely on');

    m = RotelyxService.readBy(m, 'Carla', later, 2)!;
    expect(m.seenBy, ['Beto', 'Carla']);
    expect(m.seen, isTrue, reason: 'both have read it now');
  });

  test('two receipts under one name are one reader', () {
    // What the defect produced: every member attributed to the conversation.
    var m = ours();
    m = RotelyxService.readBy(m, 'Beto and 1 other', later, 2)!;

    expect(RotelyxService.readBy(m, 'Beto and 1 other', later, 2), isNull,
        reason: 'the same name twice adds nobody, which is correct, and is '
            'exactly why attributing every member to the conversation left the '
            'tick permanently one reader short');
    expect(m.seen, isFalse);
  });

  test('a conversation of two ticks on the first receipt', () {
    final m = RotelyxService.readBy(ours(), 'Beto', later, 1)!;

    expect(m.seen, isTrue,
        reason: 'one other member, one receipt. This case was always right, '
            'which is why the group case could be wrong unnoticed');
  });

  test('a mark below the message covers nothing', () {
    final before = sent.subtract(const Duration(seconds: 5));

    expect(RotelyxService.readBy(ours(), 'Beto', before, 2), isNull,
        reason: 'a high water mark below a message does not cover it, or '
            'anything sent after somebody looked would be marked read');
  });

  test('their own message is not something they read', () {
    final theirs = StoredMessage(text: 'hello', mine: false, at: sent);

    expect(RotelyxService.readBy(theirs, 'Beto', later, 2), isNull,
        reason: 'the tick belongs to what we sent');
  });

  test('a ticked message takes no more readers', () {
    var m = RotelyxService.readBy(ours(), 'Beto', later, 1)!;
    expect(m.seen, isTrue);

    expect(RotelyxService.readBy(m, 'Carla', later, 1), isNull,
        reason: 'once everybody has read it there is nothing left to record');
  });

  test('a group of eight needs all seven', () {
    var m = ours();
    for (final who in ['b', 'c', 'd', 'e', 'f', 'g']) {
      m = RotelyxService.readBy(m, who, later, 7)!;
      expect(m.seen, isFalse, reason: '$who is not the last of seven');
    }

    m = RotelyxService.readBy(m, 'h', later, 7)!;
    expect(m.seen, isTrue);
    expect(m.seenBy, hasLength(7));
  });

}
