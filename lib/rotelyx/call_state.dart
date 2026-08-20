/// Whether a call is ringing, up, or over, and who is allowed to say so.
///
/// # Why this is a separate file from the media path
///
/// `call_native.dart` moves audio. It has no idea whether anybody agreed to
/// the call, and it should not: opening a media path and agreeing to talk are
/// different things, and the bugs live in the second.
///
/// # The states, and the ones that are not obvious
///
/// A call has five, not three. "Declined" is separate from "ended" because an
/// interface that says "call ended" when somebody actively said no is telling
/// a small lie every time. And "ringing out" is separate from "ringing in"
/// because the two allow different things: only the receiver may answer, and
/// only the caller may cancel before it is answered.
///
/// # Why every transition is checked
///
/// Because both sides send, and the network reorders. An `answered` that
/// arrives after an `ended` must not resurrect a finished call, and a second
/// `answered` from a phone that retried must not restart the clock. The rule
/// is written once, here, and both the sending and the receiving path go
/// through it.
library;

import 'signal.dart';

/// Where a call is.
enum CallPhase {
  /// Nothing is happening.
  idle,

  /// We placed it and it has not been answered.
  ringingOut,

  /// They placed it and we have not answered.
  ringingIn,

  /// Both sides agreed. Audio is flowing.
  talking,

  /// Over. Held briefly so the interface can say how it ended.
  over,
}

/// How long a call rings before it gives up.
///
/// Forty five seconds. Long enough to find a phone in a bag, short enough that
/// a call nobody is near stops ringing before it becomes an alarm.
const Duration ringTimeout = Duration(seconds: 45);

/// How often the caller says it is still ringing.
///
/// Without this a caller who loses their connection mid-ring leaves the other
/// phone ringing until the timeout, and there is no way for the receiver to
/// tell that from somebody who is simply waiting.
const Duration ringHeartbeat = Duration(seconds: 5);

/// How long a missed heartbeat is tolerated before the ring is abandoned.
///
/// Three beats. One lost packet is normal, three in a row is a connection that
/// has gone.
const Duration ringSilence = Duration(seconds: 16);

/// A call, as far as agreement goes.
class CallState {
  CallState._({
    required this.phase,
    required this.id,
    required this.ended,
    required this.since,
  });

  const CallState.idle()
      : phase = CallPhase.idle,
        id = '',
        ended = null,
        since = null;

  final CallPhase phase;

  /// Which call. Empty when idle.
  final String id;

  /// How it finished, once it has.
  final CallEnded? ended;

  /// When the current phase began, for the ringing timeout and the duration
  /// shown while talking.
  final DateTime? since;

  bool get isBusy => phase != CallPhase.idle && phase != CallPhase.over;

  /// Whether audio should be flowing.
  bool get isLive => phase == CallPhase.talking;

  /// Place one.
  ///
  /// Refused while another is in progress, which is the whole reason this
  /// returns null rather than a state: an interface that lets somebody dial
  /// during a call has to decide what happens to the first one, and the answer
  /// is that it does not get to.
  CallState? place(String callId, {DateTime? now}) {
    if (isBusy) return null;
    return CallState._(
      phase: CallPhase.ringingOut,
      id: callId,
      ended: null,
      since: now ?? DateTime.now(),
    );
  }

  /// Apply something that arrived from the other side.
  ///
  /// Returns the new state, or null when the signal changes nothing. Null is
  /// the common case and is not a failure: a heartbeat for the call already
  /// ringing, or an `ended` for a call that already ended, both arrive
  /// routinely and both mean nothing has to happen.
  CallState? apply(CallSignal what, String callId, {DateTime? now}) {
    final at = now ?? DateTime.now();

    switch (what) {
      case CallSignal.ringing:
        // Somebody is calling. Refused while busy, and the refusal is sent
        // back as a decline so their phone stops rather than ringing out.
        if (isBusy) return null;
        return CallState._(
          phase: CallPhase.ringingIn,
          id: callId,
          ended: null,
          since: at,
        );

      case CallSignal.stillRinging:
        // Only for the call already ringing here. A heartbeat for anything
        // else is from a call this device declined or never saw.
        if (phase != CallPhase.ringingIn || callId != id) return null;
        return CallState._(
          phase: phase,
          id: id,
          ended: null,
          // Not `at`: the ring started when it started. This only proves the
          // caller is still there, and moving `since` would mean a call that
          // keeps beating never times out.
          since: since,
        );

      case CallSignal.answered:
        // Only the call we placed, and only while it is still ringing. An
        // `answered` that arrives after an `ended` must not resurrect it, and
        // a second one from a phone that retried must not restart the clock.
        if (phase != CallPhase.ringingOut || callId != id) return null;
        return CallState._(
          phase: CallPhase.talking,
          id: id,
          ended: null,
          since: at,
        );

      case CallSignal.declined:
        if (!isBusy || callId != id) return null;
        return _finished(CallEnded.declined);

      case CallSignal.ended:
        if (!isBusy || callId != id) return null;
        return _finished(
            phase == CallPhase.ringingOut ? CallEnded.unanswered : CallEnded.hungUp);
    }
  }

  /// This device answers.
  CallState? answer({DateTime? now}) {
    if (phase != CallPhase.ringingIn) return null;
    return CallState._(
      phase: CallPhase.talking,
      id: id,
      ended: null,
      since: now ?? DateTime.now(),
    );
  }

  /// This device hangs up, declines, or gives up ringing.
  CallState? end(CallEnded why) {
    if (!isBusy) return null;
    return _finished(why);
  }

  /// Whether a call that is ringing has rung long enough.
  ///
  /// Checked by the screen on a timer rather than scheduled, because a
  /// scheduled one has to be cancelled on every other path out of ringing and
  /// the path that forgets leaves a call that ends by itself a minute later.
  bool ringingTooLong({DateTime? now}) {
    if (phase != CallPhase.ringingIn && phase != CallPhase.ringingOut) {
      return false;
    }
    final began = since;
    if (began == null) return false;
    return (now ?? DateTime.now()).difference(began) > ringTimeout;
  }

  /// How long this call has been up.
  Duration? get talkingFor {
    if (phase != CallPhase.talking || since == null) return null;
    return DateTime.now().difference(since!);
  }

  CallState _finished(CallEnded why) => CallState._(
        phase: CallPhase.over,
        id: id,
        ended: why,
        since: DateTime.now(),
      );

  /// Back to nothing, once the interface has shown how it ended.
  CallState get cleared => const CallState.idle();

  @override
  String toString() => 'CallState(${phase.name}, id: $id, ended: ${ended?.name})';
}

/// How a call ended, which the interface has to tell apart.
enum CallEnded {
  /// Somebody hung up.
  hungUp,

  /// They said no.
  declined,

  /// It rang out.
  unanswered,

  /// The session went away underneath it.
  lost,
}
