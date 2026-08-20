/// Who may answer, decline and hang up, and what a late signal may not undo.
///
/// # Why this deserves its own tests
///
/// Because both sides send and the network reorders. An `answered` that arrives
/// after an `ended` must not resurrect a finished call. A second `answered`
/// from a phone that retried must not restart the clock. A `ringing` for a call
/// this device already declined must not start it again.
///
/// None of that is visible from reading the happy path, and all of it happens
/// on a real network within the first week.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/call_state.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

void main() {
  const idle = CallState.idle();

  test('placing a call rings out, and a second one is refused', () {
    final ringing = idle.place('call-one')!;
    expect(ringing.phase, CallPhase.ringingOut);
    expect(ringing.id, 'call-one');
    expect(ringing.isBusy, isTrue);

    expect(ringing.place('call-two'), isNull,
        reason: 'dialling during a call would leave the first one nowhere');
  });

  test('a ring arrives and is answered', () {
    final ringing = idle.apply(CallSignal.ringing, 'call-one')!;
    expect(ringing.phase, CallPhase.ringingIn);

    final talking = ringing.answer()!;
    expect(talking.phase, CallPhase.talking);
    expect(talking.isLive, isTrue);
  });

  test('an answer for a call that already ended does not resurrect it', () {
    // The reordering case. Both sides send, and the network does not promise
    // an order.
    final ringing = idle.place('call-one')!;
    final over = ringing.end(CallEnded.hungUp)!;

    expect(over.apply(CallSignal.answered, 'call-one'), isNull);
    expect(over.phase, CallPhase.over);
  });

  test('a second answer does not restart the clock', () {
    final ringing = idle.place('call-one')!;
    final talking = ringing.apply(CallSignal.answered, 'call-one')!;

    expect(talking.apply(CallSignal.answered, 'call-one'), isNull,
        reason: 'a phone that retried must not reset the duration');
  });

  test('a signal for another call is ignored', () {
    // Two people pressing call at the same moment produce two calls. Without
    // the identifier, answering one would end the other.
    final ringing = idle.place('mine')!;

    expect(ringing.apply(CallSignal.answered, 'theirs'), isNull);
    expect(ringing.apply(CallSignal.ended, 'theirs'), isNull);
    expect(ringing.phase, CallPhase.ringingOut);
  });

  test('declined and ended are different endings', () {
    // An interface that says "call ended" when somebody actively said no is
    // telling a small lie every time.
    final ringing = idle.place('call-one')!;

    expect(ringing.apply(CallSignal.declined, 'call-one')!.ended,
        CallEnded.declined);
    expect(ringing.apply(CallSignal.ended, 'call-one')!.ended,
        CallEnded.unanswered,
        reason: 'ended while still ringing out means nobody picked up');
  });

  test('hanging up mid-call reads as hung up, not unanswered', () {
    final talking = idle
        .place('call-one')!
        .apply(CallSignal.answered, 'call-one')!;

    expect(talking.apply(CallSignal.ended, 'call-one')!.ended,
        CallEnded.hungUp);
  });

  test('a heartbeat proves the caller is there without extending the ring', () {
    final began = DateTime(2026, 1, 1, 12);
    final ringing = idle.apply(CallSignal.ringing, 'call-one', now: began)!;

    final beaten = ringing.apply(CallSignal.stillRinging, 'call-one',
        now: began.add(const Duration(seconds: 10)))!;

    expect(beaten.since, began,
        reason: 'a call that keeps beating would otherwise never time out');
  });

  test('a heartbeat for a call this device is not on changes nothing', () {
    expect(idle.apply(CallSignal.stillRinging, 'whatever'), isNull);
  });

  test('a call that rings too long is recognised', () {
    final began = DateTime(2026, 1, 1, 12);
    final ringing = idle.place('call-one', now: began)!;

    expect(ringing.ringingTooLong(now: began.add(const Duration(seconds: 10))),
        isFalse);
    expect(
        ringing.ringingTooLong(
            now: began.add(ringTimeout + const Duration(seconds: 1))),
        isTrue);
  });

  test('a call that is up never times out for ringing', () {
    final began = DateTime(2026, 1, 1, 12);
    final talking =
        idle.place('call-one', now: began)!.apply(CallSignal.answered, 'call-one')!;

    expect(talking.ringingTooLong(now: began.add(const Duration(hours: 2))),
        isFalse);
  });

  test('the ring timeout and its heartbeat are consistent', () {
    // The heartbeat has to beat several times inside the timeout, or a caller
    // who is present looks like one who has gone.
    expect(ringTimeout.inSeconds ~/ ringHeartbeat.inSeconds, greaterThan(5));
    expect(ringSilence, greaterThan(ringHeartbeat * 2),
        reason: 'one lost beat is normal; three in a row is a connection gone');
  });
}
