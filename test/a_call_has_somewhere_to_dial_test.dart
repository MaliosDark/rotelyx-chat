/// Fails the build if a call can be placed with nowhere to dial.
///
/// # The defect this exists for
///
/// Calls are relay-only and connection-oriented: one side dials, the other
/// accepts. The side that dials is the caller, and the ring it sent carried
/// **its own** address outward. So the only way the caller learns where to
/// dial is for the answer to carry an address back.
///
/// For eleven days it did not. `answer()` sent `CallSignal.answered` with an
/// identifier and no address, and `_open` dialled `_theirAddress ?? ''`. The
/// engine refuses an empty address as undecodable, `_open` caught the throw,
/// and the screen said "Connection lost". Both phones showed it. Neither ever
/// opened a microphone: the caller threw before the audio loop started, and
/// the answerer waited out its ten seconds for a peer that never dialled.
///
/// Nothing failed. Every test passed, because the tests cover the state
/// machine in `call_state.dart` and the engine in `call_test.dart`, and the
/// missing argument was in neither. The controller is a singleton wired to the
/// global service and has no unit test at all.
///
/// So this reads the source, in the manner of
/// `no_foreign_infrastructure_test.dart`. It is a weaker check than exercising
/// the controller, and it is here because it is the check that could be
/// written today without restructuring the singleton. It holds the two
/// properties whose absence produced the defect.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/rotelyx/calls.dart').readAsStringSync();

  test('the answer carries an address, because the caller dials', () {
    final answered = RegExp(
      r'Signal\.call\(\s*CallSignal\.answered\b[^;]*?\)',
      dotAll: true,
    ).firstMatch(source);

    expect(
      answered,
      isNotNull,
      reason: 'answer() no longer sends CallSignal.answered. If the handshake '
          'changed, this test has to change with it rather than be deleted: '
          'whatever replaces it still has to tell the caller where to dial.',
    );

    expect(
      answered!.group(0),
      contains('address:'),
      reason: 'The answer goes out with no address. The caller then dials an '
          'empty string, the engine refuses it, and both ends report a lost '
          'connection having never opened a microphone.',
    );
  });

  test('nothing dials an address that may be empty', () {
    expect(
      source,
      isNot(contains("connect(_theirAddress ?? '')")),
      reason: 'Falling back to an empty address turns "nobody sent me an '
          'address" into "that address will not decode", which reaches the '
          'screen as a lost connection and hides the real cause. Refuse with '
          'the reason instead.',
    );

    expect(
      source,
      contains("they answered without an address to dial"),
      reason: 'The guard that says so is gone. Without it the empty-address '
          'case is silent again.',
    );
  });

  test('the ring carries an address too, which is the half that worked', () {
    final ringing = RegExp(
      r'Signal\.call\(\s*CallSignal\.ringing\b[^;]*?\)',
      dotAll: true,
    ).firstMatch(source);

    expect(ringing, isNotNull);
    expect(
      ringing!.group(0),
      contains('address:'),
      reason: 'The answerer needs the caller address to accept a call it did '
          'not place. This half was always right; it is pinned so a change to '
          'the handshake cannot quietly drop it while fixing the other half.',
    );
  });
}
