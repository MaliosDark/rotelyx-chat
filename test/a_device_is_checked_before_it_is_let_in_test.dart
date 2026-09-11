/// The digits two devices compare, reached from the application's side.
///
/// # Why this deserves a test here and not only in the engine
///
/// Adding a device is an addition to every conversation its person is in, so a
/// substituted key package is the worst outcome available in this application.
/// The engine catches one; what this pins is that the path from here reaches
/// that check and reaches it over the bytes that arrived.
///
/// The mistake being guarded against is invisible in any honest test: a
/// confirmation computed from the local copy of what was sent agrees with
/// itself perfectly and protects nothing. So the attacker is in the test.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_wasm.dart';

void main() {
  test('a device of a person is its own member', () {
    final phone = RotelyxWasm.newDeviceSession('ana', 'phone');
    final laptop = RotelyxWasm.newDeviceSession('ana', 'laptop');

    expect(phone.keyPackage(), isNot(laptop.keyPackage()),
        reason: 'two devices of one person are two identities, not one copied');
  });

  test('a substituted key package reads as different digits', () {
    final laptop = RotelyxWasm.newDeviceSession('ana', 'laptop');
    final mine = laptop.keyPackage();

    final honest = RotelyxWasm.deviceConfirmation(mine);
    expect(honest, isNotEmpty);
    expect(RotelyxWasm.deviceConfirmation(mine), honest,
        reason: 'both ends must read the same digits from the same package');

    final attacker = RotelyxWasm.newDeviceSession('ana', 'laptop');
    expect(
      RotelyxWasm.deviceConfirmation(attacker.keyPackage()),
      isNot(honest),
      reason: 'somebody else\'s package read as the same digits, so the person '
          'comparing them would have approved it into every conversation',
    );
  });
}
