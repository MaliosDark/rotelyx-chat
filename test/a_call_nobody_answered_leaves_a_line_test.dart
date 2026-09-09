/// A call that was never answered has to survive the call ending.
///
/// # Why this deserves its own tests
///
/// Until this existed, a call that rang and stopped left nothing anywhere: no
/// history list, and no line in the conversation. Somebody whose phone was in
/// another room could not learn that they had been called. The state machine
/// knew, in `CallEnded.unanswered`, and threw the answer away.
///
/// What is tested here is the part that has to keep working while the rest
/// changes: that the note survives a round trip through storage, that a
/// conversation written by an older build still loads, and that a name this
/// build has never heard of does not take the whole conversation down with it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

void main() {
  final at = DateTime.fromMillisecondsSinceEpoch(1757000000000);

  test('a missed call survives being written down and read back', () {
    for (final note in CallNote.values) {
      final line = StoredMessage(
        text: 'Missed call',
        mine: false,
        at: at,
        call: note,
      );

      final back = StoredMessage.fromJson(line.toJson());

      expect(back.call, note);
      expect(back.text, 'Missed call',
          reason: 'the sentence is stored as well as the kind, so a build that '
              'predates the kind still has something to draw');
      expect(back.mine, isFalse);
      expect(back.at, at);
    }
  });

  test('an ordinary message carries no call, before and after storage', () {
    final message = StoredMessage(text: 'hello', mine: true, at: at);
    expect(message.call, isNull);
    expect(message.toJson().containsKey('c'), isFalse,
        reason: 'an absent field costs nothing in every message that is not a '
            'call, which is almost all of them');
    expect(StoredMessage.fromJson(message.toJson()).call, isNull);
  });

  test('a conversation written before call lines still loads', () {
    // Exactly the shape the previous build wrote: no `c` at all.
    final old = StoredMessage.fromJson({
      't': 'sent before any of this existed',
      'm': true,
      'a': at.millisecondsSinceEpoch,
    });

    expect(old.call, isNull);
    expect(old.text, 'sent before any of this existed');
  });

  test('a kind from a later build reads as an ordinary message', () {
    // The failure this prevents is the whole conversation refusing to load
    // because one line names something this build has never heard of.
    final future = StoredMessage.fromJson({
      't': 'Call ended',
      'm': false,
      'a': at.millisecondsSinceEpoch,
      'c': 'somethingThisBuildHasNeverHeardOf',
    });

    expect(future.call, isNull);
    expect(future.text, 'Call ended',
        reason: 'which is why the sentence is stored beside the kind');
  });

  test('copyWith keeps the call, so editing a line cannot silently unmake it',
      () {
    final line = StoredMessage(
      text: 'Missed call',
      mine: false,
      at: at,
      call: CallNote.missed,
    );

    expect(line.copyWith(seen: true).call, CallNote.missed);
  });
}
