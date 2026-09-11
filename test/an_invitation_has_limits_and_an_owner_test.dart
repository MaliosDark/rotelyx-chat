/// A meeting phrase that can be closed, counted and given a deadline.
///
/// # What it used to be
///
/// The tag is a hash of the phrase, so the phrase was **infinite and
/// irrevocable**: it never expired, nobody counted who had walked through it,
/// and the only way to close it was to agree a different phrase with everybody
/// already inside. Somebody removed from a group could knock again with the
/// same words and be let back in.
///
/// Banning them instead does not work here and is worth writing down: nothing
/// identifies a person across conversations, so anybody refused by their key
/// makes a new one in a second and knocks again as a stranger. The invitation
/// is the thing that can be controlled, so the invitation is what carries the
/// limits.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

void main() {
  final anyTag = 'a' * 64;

  StoredConversation group({
    String? tag = 'unset',
    DateTime? expires,
    int? cap,
    int used = 0,
    bool approval = true,
  }) =>
      StoredConversation(
        id: 'g1',
        title: 'a group',
        session: '',
        messages: [],
        lastActivity: DateTime.now(),
        meetingTag: tag == 'unset' ? anyTag : tag,
        meetingExpires: expires,
        meetingMaxUses: cap,
        meetingUses: used,
        meetingNeedsApproval: approval,
      );

  test('a plain invitation opens the door', () {
    expect(group().meetingIsOpen, isTrue);
    expect(group().meetingClosedBecause, isNull);
  });

  test('turning it off closes it, which is what removing somebody needs', () {
    final off = group(tag: null);
    expect(off.meetingIsOpen, isFalse);
    expect(off.meetingClosedBecause, contains('turned off'));
  });

  test('a deadline that has passed closes it', () {
    final late = group(
        expires: DateTime.now().subtract(const Duration(minutes: 1)));
    expect(late.meetingIsOpen, isFalse);
    expect(late.meetingClosedBecause, contains('expired'));

    final soon =
        group(expires: DateTime.now().add(const Duration(minutes: 1)));
    expect(soon.meetingIsOpen, isTrue);
  });

  test('a used-up invitation closes it', () {
    expect(group(cap: 2, used: 1).meetingIsOpen, isTrue);
    final spent = group(cap: 2, used: 2);
    expect(spent.meetingIsOpen, isFalse);
    expect(spent.meetingClosedBecause, contains('used'));
  });

  test('approval is the default, which is what a passed-around phrase needs', () {
    // A phrase does not know who it was given to, so somebody looks. Handing
    // an invitation to one person is the case where the decision was already
    // made, and that is what turning this off means.
    expect(group().meetingNeedsApproval, isTrue);
    expect(group(approval: false).meetingNeedsApproval, isFalse);
  });

  test('a closed invitation says which of the three reasons it is', () {
    // Rather than one word for three different situations, because "expired"
    // and "used up" and "turned off" are three different things to do about it.
    expect(group(tag: null).meetingClosedBecause, contains('turned off'));
    expect(
        group(expires: DateTime.now().subtract(const Duration(days: 1)))
            .meetingClosedBecause,
        contains('expired'));
    expect(group(cap: 1, used: 1).meetingClosedBecause, contains('used'));
  });
}
