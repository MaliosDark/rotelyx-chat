/// A bot's card, and what a press sends back.
///
/// The whole point of the encoding is that a title or a label written by
/// somebody else cannot invent a button, and that an application which has
/// never seen a card loses nothing but the buttons.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/card.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

void main() {
  test('a card round trips with its buttons', () {
    final body = const BotCard(
      title: 'Where do we eat?',
      text: 'Pick one.',
      buttons: [
        CardButton(label: 'Pizza', command: '/vote 1'),
        CardButton(label: 'Ramen', command: '/vote 2'),
      ],
    ).encode();

    final card = BotCard.decode(body)!;
    expect(card.title, 'Where do we eat?');
    expect(card.text, 'Pick one.');
    expect(card.buttons.map((b) => b.label), ['Pizza', 'Ramen']);
    expect(card.buttons.map((b) => b.command), ['/vote 1', '/vote 2']);
  });

  test('a separator in a title cannot invent a button', () {
    final body = BotCard(
      title: 'odd\x01title\x1fhere',
      text: 'and\x01text',
      buttons: const [CardButton(label: 'Only', command: '/one')],
    ).encode();

    final card = BotCard.decode(body)!;
    expect(card.title, 'odd\x01title\x1fhere');
    expect(card.text, 'and\x01text');
    expect(card.buttons.length, 1, reason: 'the title made no buttons');
  });

  test('more buttons than a card may carry are dropped', () {
    final body = BotCard(
      title: 'Many',
      text: '',
      buttons: [
        for (var i = 0; i < 20; i++)
          CardButton(label: 'b$i', command: '/c$i'),
      ],
    ).encode();

    expect(BotCard.decode(body)!.buttons.length, maxButtons);
  });

  test('ordinary text is not a card', () {
    expect(BotCard.decode('just a sentence'), isNull);
    expect(BotCard.decode(''), isNull);
  });

  test('a list says what the card asked rather than its encoding', () {
    final body = const BotCard(
      title: 'Where do we eat?',
      text: 'Pick one.',
      buttons: [CardButton(label: 'Pizza', command: '/vote 1')],
    ).encode();

    expect(BotCard.summary(body), 'Where do we eat?: Pick one.');
    expect(BotCard.summary(body), isNot(contains('rx-card')));
  });

  group('what a press sends', () {
    test('the command, and nothing about the person', () {
      final wire = Signal.tap('/vote 2').encode();
      final back = Signal.decode(wire)!;
      expect(back.kind, SignalKind.tap);
      expect(back.tapped, '/vote 2');
    });

    test('it is a control message, so no conversation shows it', () {
      expect(Signal.isControl(Signal.tap('/vote 2').encode()), isTrue);
    });

    test('a separator in the command survives, because it travels encoded', () {
      final wire = Signal.tap('/say a\x1fb').encode();
      expect(Signal.decode(wire)!.tapped, '/say a\x1fb');
    });
  });
}
