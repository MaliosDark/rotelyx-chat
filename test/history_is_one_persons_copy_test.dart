/// Handing over what was said before somebody arrived.
///
/// # Why this exists at all
///
/// Forward secrecy means nobody keeps the material to rebuild a conversation,
/// so a member added at one epoch cannot read anything sealed under the last.
/// That is a promise and not a gap. There is therefore nothing the *group* can
/// give a newcomer: there is only what a person has on their device and chooses
/// to pass on.
///
/// What is pinned here is the part that could quietly become a lie: what
/// arrives is **one person's copy**, and it must never be presentable as
/// something the conversation itself asserts.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

void main() {
  final at = DateTime.fromMillisecondsSinceEpoch(1757000000000);

  StoredMessage said(String text, {bool mine = false, int minutes = 0}) =>
      StoredMessage(
        text: text,
        mine: mine,
        at: at.add(Duration(minutes: minutes)),
      );

  test('a handover survives the trip as itself', () {
    final json = jsonEncode([
      said('before they arrived', minutes: 0).toJson(),
      said('and this too', mine: true, minutes: 1).toJson(),
    ]);

    final seen = Signal.decode(Signal.history(json).encode());

    expect(seen, isNotNull);
    expect(seen!.kind, SignalKind.history);

    final rows = jsonDecode(seen.handedHistory!) as List<dynamic>;
    expect(rows.length, 2);
    expect((rows.first as Map)['t'], 'before they arrived');
  });

  test('it is control traffic, so it is not shown as a message', () {
    // Otherwise a handover would appear in the conversation as a wall of
    // base64 and would wake somebody up for it.
    final json = jsonEncode([said('x').toJson()]);
    expect(Signal.isControl(Signal.history(json).encode()), isTrue);
  });

  test('a separator inside a message cannot break the encoding', () {
    // Signals are separated by a control character, and a handover carries
    // arbitrary text somebody typed. Base64 is what stops a message containing
    // that character from being read as the end of the field.
    final awkward = jsonEncode([said('line one SEP line two').toJson()]);
    final seen = Signal.decode(Signal.history(awkward).encode());

    final rows = jsonDecode(seen!.handedHistory!) as List<dynamic>;
    expect((rows.first as Map)['t'], 'line one SEP line two');
  });

  test('an unreadable handover is refused rather than half applied', () {
    final broken = Signal(kind: SignalKind.history, fields: ['not base64 !!']);
    expect(broken.handedHistory, isNull,
        reason: 'a partial history is worse than none: it would leave somebody '
            'believing they had been given the conversation');
  });
}
