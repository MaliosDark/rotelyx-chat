/// Which mailboxes this build vouches for, and how it talks about the rest.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/mailboxes.dart';

void main() {
  test('a mailbox we ship is recognised and named', () {
    final d = describeMailbox(defaultMailbox.url);

    expect(d.familiar, isTrue);
    expect(d.title, defaultMailbox.name);
    expect(d.detail, contains('never what you say'),
        reason: 'a familiar mailbox still has to say what it can see');
  });

  test('a stranger is named as a stranger', () {
    // The case this whole file exists for. An invitation carries the mailbox it
    // was made on and anybody can run one, so an invitation can send somebody
    // to a host its sender chose.
    final d = describeMailbox('wss://someone-elses-box.example.org/mailbox');

    expect(d.familiar, isFalse);
    expect(d.title, 'someone-elses-box.example.org',
        reason: 'the host is the useful thing to show, not the whole url');
    expect(d.detail, contains('never what you say'),
        reason: 'the warning has to say what it cannot do as well as what it '
            'can, or it reads as "this host can read your messages"');
  });

  test('the name it is known by is matched on the host, not the whole url', () {
    // A path or a port differing must not turn a mailbox we run into a
    // stranger, because it is still the same machine.
    expect(knownMailbox('wss://${defaultMailbox.host}/somewhere-else'),
        isNotNull);
  });

  test('an unencrypted address is refused, and told why', () {
    final problem = mailboxProblem('ws://m1.telyx.me/mailbox');

    expect(problem, isNotNull);
    expect(problem, contains('wss://'),
        reason: 'a refusal that does not say what to do instead is a dead end');
  });

  test('nonsense is refused rather than half accepted', () {
    expect(mailboxProblem(''), isNotNull);
    expect(mailboxProblem('just some words'), isNotNull);
    expect(mailboxProblem('https://m1.telyx.me/mailbox'), isNotNull,
        reason: 'https is not a websocket scheme, and accepting it would fail '
            'later with a message about the connection rather than the address');
  });

  test('a real address is accepted', () {
    expect(mailboxProblem('wss://someone.example.org/mailbox'), isNull);
  });

  test('every shipped mailbox is encrypted and describable', () {
    for (final m in knownMailboxes) {
      expect(mailboxProblem(m.url), isNull, reason: '${m.name} is not usable');
      expect(m.name, isNotEmpty);
      expect(m.url, contains('/'), reason: 'a mailbox needs a path');
    }
  });

  test('the shipped names give nothing away', () {
    // These strings travel inside invitations, through other people's
    // messengers. A mailbox called `london` tells everyone carrying that
    // message where its sender is.
    const places = ['london', 'uk', 'eu', 'us', 'paris', 'berlin', 'frankfurt'];
    for (final m in knownMailboxes) {
      expect(places.contains(m.name.toLowerCase()), isFalse,
          reason: '${m.name} names a place, and the name is what travels');
    }
  });

  test('the default is not written down as a choice', () {
    // Storing it would freeze it. A device set up today would go on using an
    // address long after that address moved, because it kept a copy on the day
    // it was installed. Null means "whatever this build ships with".
    expect(defaultMailbox.url, isNotEmpty);
    expect(knownMailbox(defaultMailbox.url), isNotNull);
  });

  test('a mailbox somebody runs themselves is not treated as broken', () {
    // Unfamiliar is not the same as invalid, and the difference is the whole
    // feature: refusing unknown hosts would end self hosting, which is the
    // property the application argues from.
    const theirs = 'wss://box.somebody-elses-domain.org/mailbox';

    expect(mailboxProblem(theirs), isNull, reason: 'it is a valid address');
    expect(describeMailbox(theirs).familiar, isFalse, reason: 'and unfamiliar');
  });

  test('no shipped mailbox claims a country anywhere', () {
    // It used to say "United Kingdom", which this application had no way to
    // support and which the network contradicts: these hosts sit behind a
    // content network, so the address anybody resolves belongs to no country
    // in particular. Everything else here can be checked. A jurisdiction can
    // only be believed.
    const claims = [
      'united kingdom', 'england', 'germany', 'france', 'ireland',
      'netherlands', 'switzerland', 'iceland', 'sweden', 'usa',
      'united states', 'canada', 'panama', 'venezuela',
    ];

    for (final m in knownMailboxes) {
      final described = describeMailbox(m.url);
      final blob = '${m.name} ${m.url} ${described.title} ${described.detail}'
          .toLowerCase();
      for (final c in claims) {
        expect(blob.contains(c), isFalse,
            reason: '${m.name} tells the user it is in $c, which is a claim '
                'rather than something the application can check');
      }
    }
  });
}
