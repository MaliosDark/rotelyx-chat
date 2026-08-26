/// A shipped build must not carry the remote-control hook.
///
/// # What the hook is
///
/// `lib/rotelyx/e2e_web.dart` publishes the live service as `window.__rotelyx`
/// so a browser driver can pair two tabs and exercise a real conversation
/// without a person clicking through it. It is gated behind
/// `bool.fromEnvironment('e2e')`, so it is compiled out unless somebody passes
/// `--dart-define=e2e=true`.
///
/// # Why that gate is not enough on its own
///
/// Because it is one flag on one command line, and what it opens is total:
/// anything running in the page can drive the account. An audit called the
/// containment real and the blast radius total, which is exactly the shape that
/// wants a second check rather than more care.
///
/// So this test asserts the default. It passes in an ordinary run and fails in
/// a run that defines `e2e`, which makes it a gate a release pipeline can put
/// in front of a build rather than a habit somebody has to remember.
///
///   flutter test test/no_remote_control_test.dart
///
/// A driver run defines the flag on purpose and skips this file.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/e2e.dart';

void main() {
  test('the remote control hook is compiled out', () {
    expect(
      e2eEnabled,
      isFalse,
      reason: 'this build defines e2e, which publishes the live service as '
          'window.__rotelyx and lets anything in the page drive the account. '
          'It is for the browser driver and must never reach a release.',
    );
  });
}
