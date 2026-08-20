/// What an export contains, and what it must not.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/export.dart';
import 'package:rotelyx_chat/rotelyx/quoted.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

StoredConversation withMessages(List<StoredMessage> messages) =>
    StoredConversation(
      id: '1',
      title: 'Ana',
      session: null,
      lastActivity: DateTime(2026),
      messages: messages,
    );

StoredMessage msg(String text, {bool mine = false}) =>
    StoredMessage(text: text, mine: mine, at: DateTime(2026, 3, 4, 15, 7));

void main() {
  test('it says it is not encrypted, at both ends', () {
    // At the top for whoever opens the file, and at the bottom because a long
    // transcript gets scrolled past and the person who reaches the end is the
    // one about to send it somewhere.
    final text = exportConversation(withMessages([msg('hello')]));

    final warnings = 'not encrypted'.allMatches(text.toLowerCase()).length;
    expect(warnings, greaterThanOrEqualTo(2));
  });

  test('control messages are not in the transcript', () {
    // A read receipt is not something a person wrote.
    final text = exportConversation(withMessages([
      msg('a real message'),
      msg(Signal.read(DateTime(2026)).encode()),
      msg(Signal.reaction(emoji: 'x', at: DateTime(2026), remove: false).encode()),
    ]));

    expect(text.contains('a real message'), isTrue);
    expect(text.contains('rx-signal'), isFalse);
    expect(text.contains('1 messages.'), isTrue,
        reason: 'and they are not counted either');
  });

  test('a reply carries what it answered', () {
    final reply =
        const Quoted(author: 'Ana', excerpt: 'the question', reply: 'the answer')
            .encode();

    final text = exportConversation(withMessages([msg(reply, mine: true)]));

    expect(text.contains('> Ana: the question'), isTrue);
    expect(text.contains('the answer'), isTrue);
    expect(text.contains('rx-reply'), isFalse,
        reason: 'the marker is not something a person wrote');
  });

  test('no identifiers, tags or session material', () {
    // An export is for a person to read. Anything here that could correlate
    // this conversation with something else has no business in it.
    final text = exportConversation(withMessages([
      msg('one'),
      msg('two', mine: true),
    ]));

    for (final leak in ['rx-', 'tag', 'epoch', 'session', 'safety']) {
      expect(text.toLowerCase().contains(leak), isFalse,
          reason: 'the export contains "$leak"');
    }
  });

  test('who said what is attributed', () {
    final text = exportConversation(withMessages([
      msg('theirs'),
      msg('mine', mine: true),
    ]));

    expect(text.contains('You'), isTrue);
    expect(text.contains('Ana'), isTrue);
  });
}
