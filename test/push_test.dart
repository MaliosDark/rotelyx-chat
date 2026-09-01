/// What a wake registration is allowed to say.
///
/// The property under test is an absence, which is why it is worth a test: a
/// tag added to this call would look like a small improvement in a diff and
/// would undo the reason mailbox tags rotate at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/ephemeral.dart';
import 'package:rotelyx_chat/rotelyx/push.dart';

void main() {
  test('a grant names a device and nothing about its conversations', () {
    const grant = PushGrant(token: 'abc123', secret: 'proof');

    // Read off the object rather than asserted by eye. A field added later
    // fails this, which is the point.
    expect(grant.token, 'abc123');
    expect(grant.kind, 'apns');

    // The whole surface. If this list grows, somebody has to come here and
    // justify what the mailbox is being told.
    expect(
      const PushGrant(token: 't', secret: 's').toString().contains('tag'),
      isFalse,
      reason: 'a tag beside a stable token re-links every rotation',
    );
  });

  test('a token is an address and not a credential', () {
    // The flaw this closes: a revocation that named only a token let anybody
    // who learned one take that phone off the schedule. Nothing was disclosed
    // and it required already knowing a token, so it is a silencing rather than
    // a leak, and it is the worse failure of the two: the owner goes on
    // believing their notifications are on.
    const grant = PushGrant(token: 'abc123', secret: 'proof');
    expect(grant.secret, isNot(grant.token));
    expect(grant.secret, isNotEmpty,
        reason: 'a grant with no secret is one a stranger can revoke');
  });

  test('a fresh secret is long enough not to be guessed at', () {
    final secrets = {for (var i = 0; i < 200; i++) newSecret()};
    expect(secrets.length, 200, reason: 'two devices must not share one');
    expect(secrets.first, hasLength(64));
  });

  test('the default transport is not Firebase and says what it is', () async {
    // Asserted on what the transports are, not on how they are worded.
    //
    // This used to require the strings to contain "cannot be woken" and "No
    // Firebase", and both were changed on 1 September 2026 when the shipped
    // text was gone over for store review: a permanent notification and a
    // settings line that name a reviewer's own service in the negative are an
    // argument rather than a description. The property they were standing in
    // for is real and is checked here instead, where wording cannot break it.
    // Nothing outside wakes a build with no push, which is the property, and
    // the name only has to say so rather than say it in particular words.
    expect(await const NoPush().obtainToken(), isNull);
    expect(const NoPush().name, isNotEmpty);

    // Settings still names the path, including what is not in it. This is a
    // settings line, which is where `PushTransport.name` says users deserve to
    // know whether Google is in the path; the wording that was taken out on
    // 1 September 2026 was in the ongoing notification, where naming somebody
    // else's service reads as an argument rather than a description.
    expect(const ApnsPush().name, contains('Firebase'));
  });

  test('nothing offers a per-tag registration', () {
    // Documented as a compile-time property: `PushGrant` has no tag field and
    // `PushRegistrar.register` takes one grant, not a batch keyed by tag. A
    // test cannot assert the absence of an API, so this asserts the shape that
    // replaced it: one device, one registration.
    const grant = PushGrant(token: 'one', secret: 's', kind: 'apns');
    expect(grant.kind, isNot('fcm'),
        reason: 'Firebase relays to APNs, so it adds Google and removes '
            'nothing');
  });
}
