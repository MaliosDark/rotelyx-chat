/// One mailbox connection asks about one conversation, and that is the point.
///
/// # What this guards
///
/// The mailbox must not be able to tell that two conversations belong to one
/// person. §1 of the threat model is that it cannot, and §ADV-4 explains how:
/// a caller presenting nothing is given a fresh capability id per connection,
/// so there is no value tying its requests together.
///
/// That holds because one conversation is live at a time and reopening one
/// opens a new socket. It is **true by accident**, and an accident is not a
/// promise: the change that broke it was three lines, passed every test in this
/// suite, and had to be taken out the same night it was written. It subscribed
/// to every conversation's addresses from one connection so that a call in a
/// group nobody had open could be noticed, and in doing so told the mailbox
/// which groups belonged to one device.
///
/// So this reads the source. It is a crude test and it is the one that would
/// have caught that change: what matters is not what the service does with a
/// mailbox it already has, but whether anybody ever hands it a list of
/// addresses drawn from more than one conversation.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nothing subscribes to addresses from more than one conversation', () {
    final service =
        File('${Directory.current.path}/lib/rotelyx/rotelyx_service.dart')
            .readAsStringSync();

    // Every conversation this device knows about, read from storage rather
    // than from the live session, is the shape that produced the defect: the
    // live session can only name its own addresses, and `loadAll` can name
    // everybody's.
    final walksEveryConversation = RegExp(
      r'store\.loadAll\(\)[\s\S]{0,400}?subscribe\(',
    ).hasMatch(service);

    expect(walksEveryConversation, isFalse,
        reason: 'something is collecting addresses across every stored '
            'conversation and subscribing to them. One connection asking about '
            'several conversations tells the mailbox they belong to one '
            'device, which is the first thing the threat model says it cannot '
            'know.');
  });

  test('the subscription set comes from the live session alone', () {
    final service =
        File('${Directory.current.path}/lib/rotelyx/rotelyx_service.dart')
            .readAsStringSync();

    // `myPollingTags` is on a session, so a set built from it can only ever
    // describe the conversation whose session is loaded. Anything else that
    // ends up in `subscribe` is worth a second look by whoever changed it.
    expect(service, contains('session.myPollingTags'),
        reason: 'the addresses subscribed to are derived from the live '
            'session, and that is what keeps one connection about one '
            'conversation');
  });
}
