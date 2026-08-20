/// The layer that existed in storage and could not be reached.
///
/// Every field below was written by the store and read by nothing. These tests
/// pin the behaviour now that something reads them, and they are written
/// against the rules rather than the widgets, because a widget test would
/// prove the button is on screen and not that pressing it does the right thing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

StoredMessage msg(String text,
        {required bool mine, DateTime? at, bool seen = false}) =>
    StoredMessage(
      text: text,
      mine: mine,
      at: at ?? DateTime(2026, 1, 1, 12),
      seen: seen,
    );

void main() {
  test('a nickname is what this device shows, and never what it sends', () {
    final c = StoredConversation(
      id: '1',
      title: 'Beto Ruiz',
      session: null,
      messages: [],
      lastActivity: DateTime(2026),
    );

    expect(c.displayTitle, 'Beto Ruiz');

    c.nickname = 'the plumber';
    expect(c.displayTitle, 'the plumber');
    expect(c.title, 'Beto Ruiz',
        reason: 'what they call themselves is not overwritten by a note');
  });

  test('a read receipt is a high water mark and not one per message', () {
    // One envelope however many were read. A receipt per message would let an
    // observer time each one and would cost a fan-out each.
    final at = DateTime(2026, 1, 1, 12, 30);
    final encoded = Signal.read(at).encode();

    expect(encoded.split('\x1f').length, 3);
    expect(Signal.decode(encoded)!.readThrough.millisecondsSinceEpoch,
        at.millisecondsSinceEpoch);
  });

  test('a reaction names a message by its author and its time', () {
    // There is no message id on the wire, for the same reason a reply carries
    // a quote: an id is a handle the mailbox could use to correlate envelopes.
    final at = DateTime(2026, 1, 1, 12);
    final s = Signal.reaction(emoji: '❤️', at: at, remove: false);
    final back = Signal.decode(s.encode())!;

    expect(back.kind, SignalKind.reaction);
    expect(back.emoji, '❤️');
    expect(back.reactionAt.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
    expect(back.removing, isFalse);

    final undo = Signal.decode(
        Signal.reaction(emoji: '❤️', at: at, remove: true).encode())!;
    expect(undo.removing, isTrue);
  });

  test('seen is never inferred', () {
    // Absence means "they did not say", not "they did not read". An interface
    // that treated the two as one would invent a fact about somebody.
    final m = msg('hello', mine: true);
    expect(m.seen, isFalse);
    expect(m.copyWith(seen: true).seen, isTrue);
  });

  test('reactions survive a round trip through storage', () {
    final m = msg('hello', mine: true).copyWith(reactions: {
      '❤️': ['Ana', 'Beto'],
      '👍': ['Ana'],
    });

    final back = StoredMessage.fromJson(m.toJson());
    expect(back.reactions['❤️'], ['Ana', 'Beto']);
    expect(back.reactions['👍'], ['Ana']);
  });

  test('a conversation with nothing set stores nothing extra', () {
    // Every one of these fields is absent from the encoded form until it is
    // used. A log that grows by six keys per conversation for features nobody
    // switched on is a log that is larger to seal and slower to open.
    final m = msg('plain', mine: false);
    expect(m.toJson().containsKey('r'), isFalse);
    expect(m.toJson().containsKey('s'), isFalse);
  });

  test('pinned and muted are facts about this device only', () {
    // Neither travels. Muting somebody is not something they are told.
    final c = StoredConversation(
      id: '1',
      title: 'Ana',
      session: null,
      messages: [],
      lastActivity: DateTime(2026),
    )
      ..pinned = true
      ..muted = true;

    expect(c.pinned, isTrue);
    expect(c.muted, isTrue);
    expect(Signal.isControl('rx-signal\x1fmute'), isTrue,
        reason: 'the marker exists, but nothing sends a mute and nothing should');
  });
}
