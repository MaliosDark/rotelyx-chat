// Admitting a member takes two of them, and the screen has to make that a
// decision somebody can actually take.
//
// The protocol half is tested where it lives: a commit that admits somebody on
// the authority of the member that sent it is refused by every receiver, and
// the epoch does not move. What is tested here is the half that decides whether
// any of that reaches a person: the request that travels beside the proposal,
// carrying the two things a key package does not have, and the state the screen
// reads to put the decision in front of somebody.

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_service.dart';

void main() {
  group('asking the group to let somebody in', () {
    test('carries the address the welcome has to go to', () {
      // The member who confirms is not the member who was asked, and a meeting
      // tag is a hash of a phrase nobody stores. Without this in the request,
      // whoever agrees has no way to reach the person waiting.
      final signal = Signal.pendingAddition(
        meetingTag: 'a' * 64,
        name: 'Mar',
      );

      final back = Signal.decode(signal.encode());

      expect(back, isNotNull);
      expect(back!.kind, SignalKind.pendingAddition);
      expect(back.pendingMeetingTag, 'a' * 64);
      expect(back.pendingName, 'Mar');
    });

    test('is control traffic, not something anybody reads as a message', () {
      final signal = Signal.pendingAddition(meetingTag: 'b' * 64, name: 'Mar');
      expect(Signal.decode(signal.encode()), isNotNull);
      expect(Signal.decode('just something somebody typed'), isNull);
    });

    test('a name carrying the field separator survives', () {
      // The name is chosen by whoever is knocking, so it is exactly the field
      // somebody would put a separator in to see what happens. It travels as
      // base64 for this reason.
      final nasty = 'Maradmin';
      final signal = Signal.pendingAddition(
        meetingTag: 'c' * 64,
        name: nasty,
      );
      final back = Signal.decode(signal.encode());
      expect(back!.pendingName, nasty);
      expect(back.pendingMeetingTag, 'c' * 64);
    });

    test('a name that is not readable does not take the request down with it',
        () {
      // A request whose name cannot be decoded is still a request: the address
      // is what the group needs in order to act on it, and refusing the whole
      // thing would let a malformed name stop somebody being let in.
      final broken = Signal(
        kind: SignalKind.pendingAddition,
        fields: ['d' * 64, 'not base64 at all !!'],
      );
      expect(broken.pendingMeetingTag, 'd' * 64);
      expect(broken.pendingName, '');
    });

    test('another kind of signal is not mistaken for one', () {
      final read = Signal.read(DateTime.now());
      expect(read.pendingMeetingTag, isNull);
    });
  });

  group('what the screen is given', () {
    test('a waiting person keeps who asked, so the group can weigh it', () {
      final waiting = PendingAddition(
        name: 'Mar',
        askedBy: 'ana',
        meetingTag: 'e' * 64,
        at: DateTime.now(),
      );

      // "Somebody joined" is a fact nobody can act on. "Ana wants to let Mar
      // in" is one the others can measure against what they already know.
      expect(waiting.askedBy, 'ana');
      expect(waiting.name, 'Mar');
      expect(waiting.meetingTag, 'e' * 64);
    });

    test('a request nobody can attribute is still shown, unattributed', () {
      final waiting = PendingAddition(
        name: 'Mar',
        askedBy: null,
        meetingTag: 'f' * 64,
        at: DateTime.now(),
      );
      expect(waiting.askedBy, isNull);
    });
  });
}
