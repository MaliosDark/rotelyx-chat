/// The invitation link, and the one property it exists for.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/invite_link.dart';

String codeWith(Object? mailbox) => base64Encode(utf8.encode(jsonEncode({
      'v': 1,
      'name': 'Ana',
      if (mailbox != null) 'mailbox': mailbox,
      'tag': 'a' * 64,
      'keyPackage': 'kp',
      'hybridPublicKey': 'hpk',
    })));

void main() {
  test('the code sits in the fragment, which no server ever receives', () {
    final link = inviteLink(codeWith('wss://m1.telyx.com/mailbox'));
    final uri = Uri.parse(link);

    // The whole point. A browser opening this asks the host for `/i` and keeps
    // the rest to itself, so the site the link names cannot log the invitation
    // even if somebody wanted it to.
    expect(uri.path, '/i');
    expect(uri.query, isEmpty,
        reason: 'a query string is sent to the server; a fragment is not');
    expect(uri.fragment, isNotEmpty);
  });

  test('a link round trips back to the code it carried', () {
    final code = codeWith('wss://m1.telyx.com/mailbox');
    expect(codeFromLink(inviteLink(code)), code);
  });

  test('a bare code is accepted too', () {
    // People paste what they were given, and what they were given depends on
    // which version of the application made it.
    final code = codeWith(null);
    expect(codeFromLink(code), code);
    expect(codeFromLink('  $code  '), code);
  });

  test('something that is neither is refused rather than guessed at', () {
    expect(codeFromLink(''), isNull);
    expect(codeFromLink('https://rotelyx.com/i'), isNull,
        reason: 'a link with no fragment carries no invitation');
  });

  test('the mailbox travels inside the code', () {
    expect(mailboxFromCode(codeWith('wss://m2.telyx.com/mailbox')),
        'wss://m2.telyx.com/mailbox');
  });

  test('a code from before mailboxes had names says nothing, not nonsense', () {
    // Null is the honest answer for those, and the caller falls back to the
    // host this build is configured with, which is the only one there was.
    expect(mailboxFromCode(codeWith(null)), isNull);
    expect(mailboxFromCode('not base64 at all'), isNull);
  });

  test('the link is a length people can actually send', () {
    // A real invitation is about 2.8 kB. Long, and deliberately not shortened:
    // a short link is a lookup on somebody's server, which turns an invitation
    // nobody can see into one host that resolves it and could keep it.
    final link = inviteLink('x' * 2836);
    expect(link.length, lessThan(4000),
        reason: 'past about four thousand characters some messaging apps and '
            'mail clients start truncating a pasted link');
  });

  test('an expiry travels inside the code and can be read back', () {
    final at = DateTime.now().add(const Duration(hours: 1));
    final code = base64Encode(utf8.encode(jsonEncode({
      'v': 1, 'name': 'Ana', 'tag': 'a' * 64,
      'expires': at.millisecondsSinceEpoch,
      'keyPackage': 'kp', 'hybridPublicKey': 'hpk',
    })));

    expect(expiryOfCode(code)!.millisecondsSinceEpoch,
        at.millisecondsSinceEpoch);
    expect(codeHasExpired(code), isFalse);
  });

  test('one from an hour ago is refused', () {
    // The reason this exists: an invitation carries the keys themselves, so
    // one that never expires is a key sitting in somebody's message history.
    // A link sent months ago still worked, and whoever found it could use it
    // and become the other side of the conversation.
    final code = base64Encode(utf8.encode(jsonEncode({
      'v': 1, 'name': 'Ana', 'tag': 'a' * 64,
      'expires': DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      'keyPackage': 'kp', 'hybridPublicKey': 'hpk',
    })));

    expect(codeHasExpired(code), isTrue);
  });

  test('a clock two minutes out does not kill a live invitation', () {
    // Rejecting one because the sender's phone is fast would be a failure
    // neither screen could explain.
    final code = base64Encode(utf8.encode(jsonEncode({
      'v': 1, 'name': 'Ana', 'tag': 'a' * 64,
      'expires': DateTime.now()
          .subtract(const Duration(minutes: 2))
          .millisecondsSinceEpoch,
      'keyPackage': 'kp', 'hybridPublicKey': 'hpk',
    })));

    expect(codeHasExpired(code), isFalse);
  });

  test('no limit and no field both mean unlimited, and say so honestly', () {
    for (final value in [0, null]) {
      final code = base64Encode(utf8.encode(jsonEncode({
        'v': 1, 'name': 'Ana', 'tag': 'a' * 64,
        if (value != null) 'expires': value,
        'keyPackage': 'kp', 'hybridPublicKey': 'hpk',
      })));
      expect(expiryOfCode(code), isNull);
      expect(codeHasExpired(code), isFalse);
    }
  });
}
