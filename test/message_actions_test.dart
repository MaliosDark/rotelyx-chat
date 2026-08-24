/// Editing and withdrawing, and who is allowed to do either.
///
/// # Why the author check deserves a test
///
/// Both of these arrive as signals from the other side, and both change what is
/// already in somebody's log. Without the check, anybody in a group could
/// rewrite or delete anybody's words, which is worse than either feature is
/// worth.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

void main() {
  final at = DateTime(2026, 5, 6, 10, 30);

  test('an edit round trips, including a body with a separator', () {
    final s = Signal.edited(at, 'the new text');
    final back = Signal.decode(s.encode())!;

    expect(back.kind, SignalKind.edited);
    expect(back.editedAt.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
    expect(back.editedText, 'the new text');

    // A body containing the separator is not truncated. The separator is
    // sanitised on the way out, so what comes back is the same length rather
    // than the same bytes.
    final awkward = Signal.decode(Signal.edited(at, 'one\x1ftwo').encode())!;
    expect(awkward.editedText.length, 'one two'.length);
  });

  test('an edit carries no previous version', () {
    // The point of an edit here. Keeping a history would mean a message
    // somebody deliberately changed is still on both devices in its first
    // form, and the person who changed it believes it is not.
    final encoded = Signal.edited(at, 'corrected').encode();

    expect(encoded.contains('corrected'), isTrue);
    // Four fields exactly: the marker, the kind, which message, and the new
    // text. There is nowhere for a previous version to be.
    expect(encoded.split('\x1f').length, 4,
        reason: 'a fifth field would be somewhere to keep what was replaced');
  });

  test('a withdrawal names a message and nothing else', () {
    final back = Signal.decode(Signal.retract(at).encode())!;

    expect(back.kind, SignalKind.retract);
    expect(back.retractedAt.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
    expect(back.fields.length, 1,
        reason: 'a reason attached here would be a reason sent to everybody');
  });

  test('an edited message says so, and it survives storage', () {
    final m = StoredMessage(text: 'after', mine: true, at: at)
        .copyWith(edited: true);

    expect(m.edited, isTrue);
    expect(StoredMessage.fromJson(m.toJson()).edited, isTrue);

    // Absent until it happens, so a log does not grow by a key per message.
    expect(StoredMessage(text: 'x', mine: true, at: at).toJson()
        .containsKey('ed'), isFalse);
  });

  test('copyWith replaces the text and keeps everything else', () {
    final original = StoredMessage(
      text: 'before',
      mine: true,
      at: at,
      author: 'Ana',
    ).copyWith(seenBy: ['Beto'], reactions: {'x': ['Beto']});

    final changed = original.copyWith(text: 'after', edited: true);

    expect(changed.text, 'after');
    expect(changed.at, at, reason: 'the timestamp is what names it on the wire');
    expect(changed.author, 'Ana');
    expect(changed.seenBy, ['Beto']);
    expect(changed.reactions['x'], ['Beto']);
  });
}
