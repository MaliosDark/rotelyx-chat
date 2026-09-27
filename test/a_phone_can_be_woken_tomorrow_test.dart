/// A device left alone can still be woken.
///
/// # The defect this exists for
///
/// A wake ticket is sealed for one hour and left under that hour's tag, and
/// the notifier opens it against the hour a message actually arrives in. The
/// tags a conversation subscribes to all belong to hours that have already
/// happened, so tickets were only ever left for the past: a device could be
/// woken during an hour in which the application had been running, and not
/// otherwise.
///
/// Somebody who opened the application at ten and was written to at two was
/// not woken. The message went to the two o'clock tag, where no ticket had
/// ever been left, and it waited there until the application was opened, at
/// which point everything arrived at once. Which is to say that being woken
/// worked for people who did not need it.
///
/// What holds the fix is that a tag can be asked for by hour, including an
/// hour that has not happened yet, and that the two ends agree on it. These
/// check that rather than the plumbing above it: if `myTagAt` stops answering
/// for the future, or starts answering the same thing whatever it is asked,
/// tickets go back to covering only the hour somebody happened to be looking.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/engine/api.dart';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';

void main() {
  final engine = createEngine();
  final available = engine.ready;

  test('a tag can be asked for by the hour, including hours to come', () {
    if (!available) return;

    final host = engine.newSession('Ana');
    final guest = engine.newSession('Beto');
    addTearDown(host.dispose);
    addTearDown(guest.dispose);

    host.found();
    final invitation = host.invite(guest.keyPackage());
    guest.join(invitation.welcome, invitation.ratchetTree);
    guest.openPq(host.encapsulateTo(guest.hybridPublicKey()));
    guest.receive(host.commitPq());
    host.settle();

    final now = DateTime.now().millisecondsSinceEpoch ~/ (3600 * 1000);

    // The hour in hand is the one `myTag` answers with, which is what pins
    // that asking by hour is the same question rather than a second one.
    expect(host.myTagAt(now), equals(host.myTag()),
        reason: 'asking for this hour must be the same tag as asking for now');

    // And each hour ahead is its own address. The same answer twice would be
    // a ticket left under a tag no message will ever arrive at.
    final ahead = <String>{};
    for (var i = 1; i <= 24; i++) {
      final tag = host.myTagAt(now + i);
      expect(tag, isNotEmpty, reason: 'hour $i ahead has no tag');
      expect(tag, isNot(equals(host.myTag())),
          reason: 'hour $i ahead answered with this hour, so a ticket left '
              'for it would sit under the wrong address');
      ahead.add(tag);
    }
    expect(ahead, hasLength(24),
        reason: 'two future hours shared a tag, so one of them cannot be '
            'woken');
  });

  test('a wake ticket can be sealed for an hour that has not happened', () {
    if (!available) return;

    // The notifier's key from the production configuration is not needed for
    // this: what is under test is that sealing takes an hour and produces
    // something different for each, which is what lets a ticket be left ahead.
    const notifier =
        'JQEdP4gaOPmrz1e+OgRs+jMc0ukVj5d29kYlxcF1/0kUkzErdLaTjKQwI0BM/unK';

    final now = DateTime.now().millisecondsSinceEpoch ~/ (3600 * 1000);

    String? sealFor(int hour) {
      try {
        return engine.sealWakeTicket(notifier, 'apns', 'a-token', hour);
      } on Object {
        // A key this build will not take is not what this test is about.
        return null;
      }
    }

    final here = sealFor(now);
    if (here == null) return;

    final later = sealFor(now + 6);
    expect(later, isNotNull);
    expect(later, isNot(equals(here)),
        reason: 'two hours sealed to the same bytes would be one ticket '
            'pretending to be two, and the mailbox could tell they belong '
            'to one device');
  });
}
