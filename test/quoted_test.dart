/// Replies, which travel as a quote rather than as a pointer.
///
/// There is no message id on the wire, by design: an id is a handle the mailbox
/// could use to correlate one envelope with another. So a reply carries a short
/// copy of what it answers, and these tests pin down that it survives the trip,
/// that an ordinary message is untouched, and that a malformed one is refused
/// rather than half read.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/quoted.dart';

void main() {
  test('a reply round trips', () {
    const q = Quoted(
        author: 'Ana', excerpt: 'shall we meet at six', reply: 'make it seven');
    final back = Quoted.decode(q.encode());

    expect(back, isNotNull);
    expect(back!.author, 'Ana');
    expect(back.excerpt, 'shall we meet at six');
    expect(back.reply, 'make it seven');
  });

  test('an ordinary message is not a reply and is not altered', () {
    expect(Quoted.decode('just a message'), isNull);
    expect(Quoted.decode(''), isNull);
    expect(Quoted.plain('just a message'), 'just a message');
  });

  test('a long quote is trimmed rather than resent whole', () {
    final long = 'x' * 400;
    final back = Quoted.decode(
        Quoted(author: 'Ana', excerpt: long, reply: 'ok').encode())!;

    expect(back.excerpt.length, lessThanOrEqualTo(quoteLimit + 3));
    expect(back.excerpt, endsWith('...'));
    expect(back.reply, 'ok');
  });

  test('a separator in the text does not truncate the reply', () {
    // Separators are stripped on the way out rather than escaped, so what
    // arrives is intact even though it is not byte-identical to what was typed.
    final encoded = const Quoted(
      author: 'Ana',
      excerpt: 'a question',
      reply: 'one\x1ftwo\x1fthree',
    ).encode();

    expect(Quoted.decode(encoded)!.reply, 'one two three');
  });

  test('a truncated reply is refused rather than half read', () {
    expect(Quoted.decode('rx-reply\x1fAna'), isNull);
    expect(Quoted.decode('rx-reply\x1fAna\x1fquote'), isNull);
  });

  test('one line shows the reply, not the quote', () {
    final encoded =
        const Quoted(author: 'Ana', excerpt: 'the question', reply: 'the answer')
            .encode();

    expect(Quoted.plain(encoded), 'the answer');
  });

  test('replying to a reply quotes only what was said', () {
    // Otherwise a thread accumulates every earlier quote and each message
    // carries the whole conversation.
    final first =
        const Quoted(author: 'Ana', excerpt: 'the question', reply: 'the answer')
            .encode();
    final second = Quoted(
            author: 'Beto', excerpt: Quoted.plain(first), reply: 'understood')
        .encode();

    expect(Quoted.decode(second)!.excerpt, 'the answer');
  });
}
