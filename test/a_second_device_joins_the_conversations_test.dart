/// A person's second device joining a conversation the first is already in.
///
/// # Why this is proved here and not in an application
///
/// This is the whole of what multi-device is: a device is added by a commit
/// every partner sees, it becomes a member that can speak and be spoken to, and
/// it can be taken away again without the person going with it. None of that is
/// interface work, and proving it against a running application would prove the
/// application rather than the protocol.
///
/// The design is `docs/DEVICES.md`. What is pinned here is each promise that
/// document makes, in the order it makes them.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/engine/api.dart';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_wasm.dart';

void main() {
  late RotelyxEngine engine;
  setUpAll(() => engine = createEngine());

  /// Ana on her phone, talking to Bo. The starting point for each test.
  ({RotelyxSession phone, RotelyxSession bo}) paired() {
    final phone = engine.newDeviceSession('ana', 'phone');
    final bo = engine.newSession('bo');

    phone.found();
    final invitation = phone.invite(bo.keyPackage());
    bo.join(invitation.welcome, invitation.ratchetTree);

    return (phone: phone, bo: bo);
  }

  test('a laptop is added by a commit Bo sees, and then it can speak', () {
    final it = paired();
    final laptop = engine.newDeviceSession('ana', 'laptop');

    // What Ana compares before letting it in. On a scanned code there is
    // nothing to compare, but the digits exist for every other route.
    expect(RotelyxWasm.deviceConfirmation(laptop.keyPackage()), isNotEmpty);

    final before = it.phone.safetyNumber();

    // The phone adds it. Bo is told by the same commit that tells everybody
    // about any member, which is the point: a device cannot arrive quietly.
    final add = it.phone.invite(laptop.keyPackage());
    it.bo.receive(add.commit);
    laptop.join(add.welcome, add.ratchetTree);

    expect(it.phone.safetyNumber(), isNot(before),
        reason: 'a device was added and the digits did not move, so nobody '
            'comparing them would catch one that was added quietly');

    // Three leaves, two people.
    expect(it.phone.memberCount, 3);

    it.phone.dispose();
    it.bo.dispose();
    laptop.dispose();
  });

  test('the laptop is a member: Bo reads it, and it reads Bo', () {
    final it = paired();
    final laptop = engine.newDeviceSession('ana', 'laptop');

    final add = it.phone.invite(laptop.keyPackage());
    it.bo.receive(add.commit);
    laptop.join(add.welcome, add.ratchetTree);

    // The laptop speaks, and it reaches Bo rather than only the phone. The
    // envelope layer is the mailbox's and is not what is being proved here.
    expect(
      it.bo.receive(laptop.send('from the laptop'))?.text,
      'from the laptop',
      reason: 'a device that cannot be heard by the other person is not a '
          'member, it is a copy talking to itself',
    );

    // And Bo reaches the laptop, which is the half that proves it was given
    // keys rather than merely listed.
    expect(laptop.receive(it.bo.send('and back'))?.text, 'and back');

    it.phone.dispose();
    it.bo.dispose();
    laptop.dispose();
  });

  test('a device can be taken away without the person going with it', () {
    final it = paired();
    final laptop = engine.newDeviceSession('ana', 'laptop');

    final add = it.phone.invite(laptop.keyPackage());
    it.bo.receive(add.commit);
    laptop.join(add.welcome, add.ratchetTree);
    expect(it.phone.memberCount, 3);

    // This is why a device is a leaf rather than a shared key: a lost laptop is
    // removed on its own, and Ana's phone stays in every conversation.
    final detail =
        jsonDecode(it.phone.rosterDetail()) as List<dynamic>;
    final laptopKey = (detail.firstWhere(
      (m) => (m as Map)['device'] == 'laptop',
    ) as Map)['key'] as String;

    it.phone.removeMember(laptopKey);

    expect(it.phone.memberCount, 2,
        reason: 'removing a device must not remove its person');

    it.phone.dispose();
    it.bo.dispose();
    laptop.dispose();
  });
}
