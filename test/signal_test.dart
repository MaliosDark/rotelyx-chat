/// Control messages, which are not something a person wrote.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

void main() {
  test('a burn acknowledgement round trips', () {
    final s = Signal.burnRead(['0123456789abcdef', 'fedcba9876543210']);
    final back = Signal.decode(s.encode())!;

    expect(back.kind, SignalKind.burnRead);
    expect(back.burnIds, ['0123456789abcdef', 'fedcba9876543210']);
  });

  test('several read messages cost one envelope', () {
    // One deposit per read rather than per message. The mailbox counts
    // deposits, so this is the difference between an operator seeing that a
    // conversation was opened and seeing how much of it was in there.
    final s = Signal.burnRead(['a' * 16, 'b' * 16, 'c' * 16, 'd' * 16]);
    expect(s.encode().split('\x1f').length, 6);
  });

  test('a control message never appears as text', () {
    expect(Signal.isControl(Signal.burnRead(['a' * 16]).encode()), isTrue);
    expect(Signal.isControl('rx-burn is not a control message'), isFalse);
    expect(Signal.isControl('an ordinary sentence'), isFalse);
  });

  test('an unknown kind is dropped rather than shown', () {
    // A newer build sending something this one does not have. Showing it would
    // put a line of markers in somebody's conversation.
    expect(Signal.decode('rx-signal\x1fsomethingnew\x1fx'), isNull);
  });

  test('a separator inside a field cannot forge a second field', () {
    const s = Signal(kind: SignalKind.burnRead, fields: ['a\x1fb']);
    expect(Signal.decode(s.encode())!.fields, ['a b']);
  });
}
