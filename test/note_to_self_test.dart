/// Whether a conversation with yourself is a real conversation.
///
/// # Why this test exists before the feature does
///
/// A note to self is worth building only if it goes the whole way: sealed as an
/// MLS application message, addressed to a mailbox tag, and opened again from
/// that tag. If it does, then somebody testing the application with one device
/// has exercised the group, the addressing and the delivery, and the feature is
/// both a real thing people use and the answer to a reviewer who has nobody to
/// message.
///
/// If instead a group of one seals to nobody, the honest version is a local
/// notepad, which proves nothing about the protocol and is worth saying out
/// loud rather than shipping as if it were the same thing.
///
/// This asks the library rather than reasoning about it. `sealForGroup` is
/// Rust, and whether it counts the sender among the recipients is not something
/// the Dart side can be read to discover.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/engine/api.dart';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';

void main() {
  late RotelyxEngine engine;

  setUpAll(() => engine = createEngine());

  test('a group of one founds, and reports itself as the only member', () {
    final solo = engine.newSession('Ana');
    solo.found();

    expect(solo.memberCount, 1);
    expect(solo.roster().length, 1);
    solo.dispose();
  });

  test('a solo group has no mailbox address at all', () {
    final solo = engine.newSession('Ana');
    solo.found();

    // The finding this whole file exists for. The blind mailbox derives its tag
    // key from the group, and the group does not have one until somebody else
    // is in it. So a note to self cannot simply be a conversation of one: there
    // is nowhere to deposit it and nothing to poll.
    expect(() => solo.sealForGroup(solo.send('hello')), throwsA(anything));
    expect(() => solo.myPollingTags(2), throwsA(anything));
    solo.dispose();
  });

  test('but a device paired with itself is an ordinary two member group', () {
    // Both members are this device. To the mailbox this is indistinguishable
    // from two people, which is the point: nothing about the protocol is
    // special cased, so what a reviewer exercises here is the real path.
    final a = engine.newSession('Ana');
    final b = engine.newSession('Ana');

    a.found();
    final invitation = a.invite(b.keyPackage());
    b.join(invitation.welcome, invitation.ratchetTree);

    expect(a.memberCount, 2);
    expect(b.memberCount, 2);
    expect(a.safetyNumber(), b.safetyNumber(),
        reason: 'both halves are the same device, so the number they would '
            'read to each other has to agree');

    a.dispose();
    b.dispose();
  });

  test('and a note deposited by one half is opened by the other', () {
    final a = engine.newSession('Ana');
    final b = engine.newSession('Ana');

    a.found();
    final invitation = a.invite(b.keyPackage());
    b.join(invitation.welcome, invitation.ratchetTree);

    const written = 'the safety number is read aloud, never typed';

    final envelopes = a.sealForGroup(a.send(written));
    expect(envelopes, isNotEmpty,
        reason: 'a two member group must address the mailbox');

    // What the mailbox would have handed back to the other half.
    final read = b.receive(b.openMine(envelopes.first, 2))?.text;
    expect(read, written);

    a.dispose();
    b.dispose();
  });

  test('the tag one half deposits under is one the other half polls', () {
    final a = engine.newSession('Ana');
    final b = engine.newSession('Ana');

    a.found();
    final invitation = a.invite(b.keyPackage());
    b.join(invitation.welcome, invitation.ratchetTree);

    final deposits = a.recipientTags().toSet();
    final polls = b.myPollingTags(2).toSet();

    expect(deposits.intersection(polls), isNotEmpty,
        reason: 'otherwise the note is deposited somewhere this device never '
            'looks, and it never comes back');

    a.dispose();
    b.dispose();
  });

  test('both halves survive being sealed and brought back', () {
    // The part of `resume` most likely to be wrong. A note to self seals two
    // sessions, and if only one comes back the group still looks healthy while
    // its own notes are deposited under a tag nothing is listening to, which
    // shows up as a conversation that quietly never delivers.
    final key = engine.newKey('a passphrase long enough to be accepted');

    final a = engine.newSession('Ana');
    final b = engine.newSession('Ana');
    a.found();
    final invitation = a.invite(b.keyPackage());
    b.join(invitation.welcome, invitation.ratchetTree);

    final sealedA = a.sealSession(key);
    final sealedB = b.sealSession(key);
    a.dispose();
    b.dispose();

    final a2 = engine.unsealSession(sealedA, key);
    final b2 = engine.unsealSession(sealedB, key);

    expect(a2.memberCount, 2);
    expect(b2.memberCount, 2);

    // Both halves are copies, so the one that speaks has to move to a fresh
    // epoch first and the other has to be told. Same rule as any restored
    // conversation; a note to self is two members and gets no exemption.
    b2.receive(a2.rekeyAfterRestore());

    const written = 'this note was written before the restart';
    final envelopes = a2.sealForGroup(a2.send(written));
    expect(b2.receive(b2.openMine(envelopes.first, 2))?.text, written);

    a2.dispose();
    b2.dispose();
    key.dispose();
  });
}
