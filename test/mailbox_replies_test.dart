/// What the mailbox says back, and whether this client can hear it.
///
/// # Why this file exists
///
/// The client sent the right frames and parsed the ones it knew. What it did
/// not have was a case for `overquota`, which is how the server says it refused
/// a deposit because the period's allowance is spent. With no case and no
/// default the frame fell through, and a message that was never stored looked
/// to the person who sent it exactly like one that was.
///
/// That is the shape of every defect this client has had: not a wrong answer,
/// but a refusal that produces no error. So this file checks the refusals
/// rather than the happy path, which `rotelyx_service` already covers.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/platform/socket_api.dart';
import 'package:rotelyx_chat/rotelyx/mailbox_client.dart';

void main() {
  test('a spent allowance is reported, with the numbers', () async {
    final client = MailboxClient('wss://example.invalid/mailbox');
    final said = <String>[];
    final sub = client.errors.listen(said.add);

    client.handleFrameForTest(
      '{"op":"overquota","limit":67108864,"used":67108900,"tier":"free"}',
    );
    await Future<void>.delayed(Duration.zero);

    expect(said, hasLength(1), reason: 'a refused deposit must not be silent');
    expect(said.single, contains('not sent'),
        reason: 'the person has to be told the message did not go, which is '
            'the whole difference between this and an accepted deposit');
    expect(said.single, contains('64'),
        reason: 'a limit without its numbers is not actionable: "try later" '
            'and "you used 64 of 64 MiB" are different sentences');

    await sub.cancel();
  });

  test('a spent allowance with no numbers still says the message did not go',
      () async {
    final client = MailboxClient('wss://example.invalid/mailbox');
    final said = <String>[];
    final sub = client.errors.listen(said.add);

    // A server that answered without the fields, or an older one. The fallback
    // must still be a refusal rather than nothing: guessing at the numbers
    // would be worse than omitting them, and silence is worse than both.
    client.handleFrameForTest('{"op":"overquota"}');
    await Future<void>.delayed(Duration.zero);

    expect(said, hasLength(1));
    expect(said.single, contains('not sent'));

    await sub.cancel();
  });

  test('an accepted deposit is not reported as a failure', () async {
    final client = MailboxClient('wss://example.invalid/mailbox');
    final said = <String>[];
    final accepted = <int>[];
    final subs = [
      client.errors.listen(said.add),
      client.accepted.listen(accepted.add),
    ];

    client.handleFrameForTest('{"op":"stored"}');
    await Future<void>.delayed(Duration.zero);

    expect(accepted, [1]);
    expect(said, isEmpty, reason: 'the guard must not fire on the ordinary case');

    for (final s in subs) {
      await s.cancel();
    }
  });

  test('a held token is not presented until the free tier refuses', () async {
    final socket = _Watched();
    final client = MailboxClient('wss://example.invalid/mailbox');
    client.useSocketForTest(socket);
    client.holdToken('a' * 300); // long enough to be a blind one

    // An ordinary deposit. The token must stay where it is: a token is a stable
    // pseudonym at the mailbox, and spending it on traffic the free tier would
    // have taken links a person's conversations for nothing.
    client.deposit('AAAA');
    expect(socket.sent.where((s) => s.contains('auth')), isEmpty,
        reason: 'the token went out before anything needed it');

    // Now the mailbox refuses for the allowance. This is the moment it earns
    // its keep, and the refused envelope goes again behind it.
    client.handleFrameForTest(
      '{"op":"overquota","limit":67108864,"used":67108900,"tier":"free"}',
    );
    await Future<void>.delayed(Duration.zero);

    expect(socket.sent.any((s) => s.contains('"op":"authblind"')), isTrue,
        reason: 'a refusal a token would have answered did not present it');
    expect(socket.sent.where((s) => s.contains('"envelope":"AAAA"')).length, 2,
        reason: 'the envelope the mailbox refused was not sent again');
  });

  test('the token is presented once, not once per refusal', () async {
    final socket = _Watched();
    final client = MailboxClient('wss://example.invalid/mailbox');
    client.useSocketForTest(socket);
    client.holdToken('a' * 300);

    client.deposit('AAAA');
    client.deposit('BBBB');
    client.handleFrameForTest('{"op":"overquota","limit":1,"used":2,"tier":"free"}');
    client.handleFrameForTest('{"op":"overquota","limit":1,"used":2,"tier":"free"}');
    await Future<void>.delayed(Duration.zero);

    expect(socket.sent.where((s) => s.contains('auth')).length, 1,
        reason: 'a second auth tells the mailbox nothing it does not know');
  });

  test('a short token goes in the signed frame', () async {
    final socket = _Watched();
    final client = MailboxClient('wss://example.invalid/mailbox');
    client.useSocketForTest(socket);
    client.holdToken('a' * 119); // the length a signed token actually is

    client.deposit('AAAA');
    client.handleFrameForTest('{"op":"overquota","limit":1,"used":2,"tier":"free"}');
    await Future<void>.delayed(Duration.zero);

    expect(socket.sent.any((s) => s.contains('"op":"auth"')), isTrue);
    expect(socket.sent.any((s) => s.contains('authblind')), isFalse,
        reason: 'a signed token presented as a blind one is refused by name');
  });

  test('with no token, a refusal is reported and nothing is resent', () async {
    final socket = _Watched();
    final client = MailboxClient('wss://example.invalid/mailbox');
    client.useSocketForTest(socket);
    final said = <String>[];
    final sub = client.errors.listen(said.add);

    client.deposit('AAAA');
    client.handleFrameForTest('{"op":"overquota","limit":1,"used":2,"tier":"free"}');
    await Future<void>.delayed(Duration.zero);

    expect(said, hasLength(1), reason: 'a refused deposit must not be silent');
    expect(socket.sent.where((s) => s.contains('AAAA')).length, 1,
        reason: 'nothing to present, so nothing to retry');

    await sub.cancel();
  });
}

/// A socket that keeps what was written to it.
class _Watched implements TextSocket {
  final List<String> sent = [];

  @override
  Stream<String> get messages => const Stream.empty();

  @override
  Stream<String> get closed => const Stream.empty();

  @override
  bool get isOpen => true;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async {}
}
