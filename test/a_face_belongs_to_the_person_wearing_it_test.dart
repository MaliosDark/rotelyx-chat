/// Your picture is yours, and a contact's is theirs.
///
/// # Why this deserves its own tests
///
/// These were one field. The only picker in the application sat on a contact's
/// card, wrote `StoredConversation.picture`, and announced the same bytes to
/// the other side as the sender's own. So setting your face changed theirs, and
/// their next profile signal changed yours back: one field with two owners and
/// both of them losing it.
///
/// What is tested here is the half that travels, because that is the half a
/// change to the wire format can quietly break: an empty picture has to mean
/// "go back to the drawn one" and not "ignore me", which is the difference
/// between a withdrawal that works and a button that lies.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

void main() {
  final face = Uint8List.fromList(List.generate(64, (i) => i));

  test('a chosen face travels', () {
    final seen = Signal.decode(Signal.profile(face).encode());
    expect(seen?.picture, face);
  });

  test('an empty profile signal is a withdrawal, not noise', () {
    final seen = Signal.decode(Signal.profile(Uint8List(0)).encode());

    expect(seen, isNotNull, reason: 'it has to survive the round trip at all');
    expect(seen!.picture, isNotNull,
        reason: 'an empty picture is a value, not an absent one: the receiver '
            'tells them apart and only the empty one means "drop it"');
    expect(seen.picture, isEmpty);
  });

  test('a profile signal is recognised as control traffic', () {
    // Otherwise a picture would be shown in the conversation as a message and
    // would wake somebody up for it.
    expect(Signal.isControl(Signal.profile(face).encode()), isTrue);
  });
}
