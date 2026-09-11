/// A call with more than two people is a room, not an offer.
///
/// # The defect this closes
///
/// A ring is sent to the whole group, so in a group of five it rings four
/// phones. `answered` is read only by the device that placed the call, so when
/// one of the four picked up, **the other three heard nothing**: they went on
/// ringing until a timer gave up, each believing the call was still theirs to
/// answer. Somebody walking into a room they were already in was invisible to
/// everybody except the person who opened the door.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/call_state.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

void main() {
  const idle = CallState.idle();

  test('somebody joining opens the media path for whoever called', () {
    final ringing = idle.place('room-1')!;
    expect(ringing.phase, CallPhase.ringingOut);

    final live = ringing.apply(CallSignal.joined, 'room-1');

    expect(live?.phase, CallPhase.talking,
        reason: 'the room has somebody in it, which is the same news to the '
            'caller that an answer used to be');
  });

  test('a phone ringing about a call somebody else took stops being asked', () {
    final offered = idle.apply(CallSignal.ringing, 'room-1');
    expect(offered?.phase, CallPhase.ringingIn);

    // Another member picks up. This is the announcement the third, fourth and
    // fifth phones never used to get.
    final after = offered!.apply(CallSignal.joined, 'room-1');

    expect(after, isNotNull,
        reason: 'it has to be told something, or it goes on ringing about a '
            'call that has already been answered');
    expect(after!.phase, CallPhase.ringingIn,
        reason: 'still joinable: a room is walked into, not answered');
    expect(after.id, 'room-1');
  });

  test('one person leaving is not the room closing', () {
    final live = idle.place('room-1')!.apply(CallSignal.joined, 'room-1')!;
    expect(live.phase, CallPhase.talking);

    expect(live.apply(CallSignal.left, 'room-1'), isNull,
        reason: 'in a room of four, one person hanging up is three people '
            'still talking, and treating that as the end empties a room '
            'because somebody\'s battery died');

    // Only `ended` closes it.
    expect(live.apply(CallSignal.ended, 'room-1')?.phase, CallPhase.over);
  });

  test('a join for another call is ignored', () {
    final ringing = idle.place('room-1')!;
    expect(ringing.apply(CallSignal.joined, 'a-different-room'), isNull,
        reason: 'somebody else\'s room must not move this one');
  });
}
