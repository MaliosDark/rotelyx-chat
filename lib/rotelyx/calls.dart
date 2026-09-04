/// Placing a call, answering one, and hearing one ring.
///
/// # Why this sits between the service and the screen
///
/// The service knows a call signal arrived and has no idea whether anybody is
/// looking. A screen knows what is on it and disappears when somebody leaves.
/// Neither can own a call: one that ends because a screen closed is wrong, and
/// one that rings with nothing to answer it is worse.
///
/// So this holds the state and screens ask it. The same shape as `alerts.dart`,
/// and for the same reason.
///
/// # What ringing costs, said once and here
///
/// Every state change is an MLS message, which is a fan-out and an envelope per
/// recipient. Ringing adds one every five seconds on top. Over thirty seconds
/// that is more envelopes than a conversation usually sends in an hour, and an
/// operator sees it as a burst.
///
/// There is no way around it. A phone that is not told cannot ring, and telling
/// it through anything but the conversation would mean a second channel to key,
/// which is the thing this design refuses to have.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/call_audio.dart';
import 'call_loop.dart';
import 'call_state.dart';
import 'engine/backend.dart';
import 'engine/net_backend.dart';
import 'ephemeral.dart' show newBurnId;
import 'rotelyx_config.dart';
import 'rotelyx_service.dart';
import 'rotelyx_store.dart';
import 'signal.dart';

/// The one call this device may be on.
class Calls {
  Calls._();

  static final Calls instance = Calls._();

  CallState _state = const CallState.idle();
  CallState get state => _state;

  CallLoop? _loop;
  CallLoop? get loop => _loop;

  /// Who the call is with, as this device names them.
  String who = '';

  String? _theirAddress;
  RotelyxEndpoint? _endpoint;
  Timer? _heartbeat;
  Timer? _watchdog;
  StreamSubscription<Signal>? _signals;

  final _changes = StreamController<CallState>.broadcast();

  /// Every change of phase, for whatever is showing.
  Stream<CallState> get changes => _changes.stream;

  /// Why the last call ended, when there is more to say than "it ended".
  ///
  /// # Why this exists
  ///
  /// `_open` works out exactly why a call could not start: the connection never
  /// arrived, this build has no codec, or an exception with its own message.
  /// It returned that string and the only caller discarded it with
  /// `unawaited`, so every one of those became the same screen: **Connection
  /// lost**, with no way to tell a missing relay from a missing codec.
  ///
  /// Three different faults reading as one word is how a call that never had a
  /// codec gets investigated as a network problem.
  Stream<String> get failures => _failures.stream;
  final _failures = StreamController<String>.broadcast();

  /// The last reason, for a screen that draws rather than listens.
  String? lastFailure;

  /// Whether this build can call at all.
  ///
  /// Checked before a call button is drawn, because a button that explains
  /// itself after being pressed is worse than one that was never there.
  bool get isPossible => audioIsBuilt;

  void start() {
    _signals ??= rotelyx.calls.listen(_arrived);
  }

  /// Place a call in this conversation. Returns why not, or null when ringing.
  Future<String?> place(StoredConversation conversation) async {
    if (_state.isBusy) return 'You are already on a call.';

    // The ring is sent through whatever session is live, and this is handed the
    // conversation the user is looking at. When those are not the same the call
    // is offered to the wrong person, so settle it before anything goes out.
    if (rotelyx.conversationId != conversation.id) {
      if (!await rotelyx.resume(conversation.id)) {
        return '${conversation.displayTitle} could not be reopened.';
      }
    }

    if (!audioIsBuilt) return 'Calls are not built for this platform yet.';
    if (!await permitMicrophone()) {
      return 'The microphone permission was refused.';
    }

    final endpoint = _bind();
    if (endpoint == null) {
      return 'Calls cannot connect: ${_bindFailure ?? 'the endpoint would not open'}.';
    }

    final address = endpoint.address;
    if (address == null) return 'The connection would not open.';

    final id = newBurnId();
    final next = _state.place(id);
    if (next == null) return 'You are already on a call.';

    who = conversation.displayTitle;
    _move(next);

    // The address rides with the ring. It is filtered where it is produced:
    // no IP, just the relay, so it says nothing about where this device is.
    _say('ringing id=$id mine=$address');
    rotelyx.signal(Signal.call(CallSignal.ringing, id: id, address: address));

    // A heartbeat while it rings, so a caller who loses their connection does
    // not leave the other phone ringing with no way to tell.
    _heartbeat = Timer.periodic(ringHeartbeat, (_) {
      if (_state.phase != CallPhase.ringingOut) return;
      rotelyx.signal(Signal.call(CallSignal.stillRinging, id: id));
    });

    _watch();
    return null;
  }

  /// Answer what is ringing.
  Future<String?> answer() async {
    if (_state.phase != CallPhase.ringingIn) return null;
    if (!await permitMicrophone()) {
      hangUp(CallEnded.declined);
      return 'The microphone permission was refused.';
    }

    // The caller is the one that dials, and the only address it holds so far
    // is its own: the ring carried this device an address, not the other way
    // round. So the answer has to carry one back, and the endpoint is bound
    // here rather than inside `_open` so there is one to send. Without this
    // the caller dials an empty string, the engine refuses to decode it, and
    // both phones report a lost connection having never opened a microphone.
    final endpoint = _bind();
    if (endpoint == null) {
      hangUp(CallEnded.lost);
      return 'Calls cannot connect: ${_bindFailure ?? 'the endpoint would not open'}.';
    }
    final address = endpoint.address;
    if (address == null) {
      hangUp(CallEnded.lost);
      return 'The connection would not open.';
    }

    final next = _state.answer();
    if (next == null) return null;

    _say('answering id=${_state.id} mine=$address theirs=$_theirAddress');
    // Filtered where it is produced: no IP, just the relay. See the ring.
    rotelyx.signal(
      Signal.call(CallSignal.answered, id: _state.id, address: address),
    );
    _move(next);

    // Reported as well as returned, so the caller may ignore it and the reason
    // still reaches anybody watching. See [failures].
    final why = await _open(dialling: false);
    _report(why);
    return why;
  }

  /// End it, whatever it was doing.
  void hangUp(CallEnded why) {
    final id = _state.id;
    final next = _state.end(why);
    if (next == null) return;

    // Only a call that broke. Declined, unanswered and hung up are endings a
    // person either caused or expected, and a fault tone for those would be
    // telling them something went wrong when nothing did.
    if (why == CallEnded.lost) unawaited(playTone('failed'));

    if (id.isNotEmpty) {
      rotelyx.signal(Signal.call(
        why == CallEnded.declined ? CallSignal.declined : CallSignal.ended,
        id: id,
      ));
    }

    _teardown();
    _move(next);
    _clearLater();
  }

  // -------------------------------------------------------------------------

  void _arrived(Signal signal) {
    final what = signal.callSignal;
    if (what == null) return;

    final id = signal.callId;
    _say('arrived ${signal.callSignal} id=$id address=${signal.callAddress}');
    if (signal.callAddress.isNotEmpty) _theirAddress = signal.callAddress;

    final next = _state.apply(what, id);

    if (next == null) {
      // Refused while busy. Told rather than ignored, so their phone stops
      // ringing instead of ringing out.
      if (what == CallSignal.ringing && _state.isBusy) {
        rotelyx.signal(Signal.call(CallSignal.declined, id: id));
      }
      return;
    }

    _move(next);

    switch (next.phase) {
      case CallPhase.ringingIn:
        who = rotelyx.conversationName ?? 'Someone';
        _watch();
      case CallPhase.talking:
        // They answered what this device placed. Dialling, because the caller
        // connects and the receiver waits.
        unawaited(_open(dialling: true).then(_report));
      case CallPhase.over:
        _teardown();
        _clearLater();
      case CallPhase.idle:
      case CallPhase.ringingOut:
        break;
    }
  }

  /// Keep the reason a call failed, rather than dropping it.
  void _report(String? why) {
    if (why == null) return;
    lastFailure = why;
    _failures.add(why);
  }

  /// Open the media path, once both sides have agreed.
  Future<String?> _open({required bool dialling}) async {
    final endpoint = _endpoint ?? _bind();
    if (endpoint == null) return 'no transport';

    final session = rotelyx.session;
    if (session == null) return 'the conversation is not open';

    try {
      // Said rather than dialled blindly: an empty address is refused by the
      // engine as undecodable, which reaches the screen as a lost connection
      // and hides the fact that nobody ever sent one.
      _say('opening dialling=$dialling theirs=$_theirAddress');
      if (dialling && (_theirAddress ?? '').isEmpty) {
        hangUp(CallEnded.lost);
        return 'they answered without an address to dial';
      }

      final connection = dialling
          ? endpoint.connect(_theirAddress!)
          : await _waitForPeer(endpoint);

      _say('connection=${connection != null}');
      if (connection == null) {
        hangUp(CallEnded.lost);
        return 'the connection did not arrive';
      }

      // The identifier this call was rung with. Both ends hold it, because
      // one side minted it and the other echoed it back, and it is what keeps
      // this call's media keys off the previous call's nonces.
      final codec = openNativeCall(session, call: _state.id);
      if (codec == null) {
        connection.close();
        hangUp(CallEnded.lost);
        return 'this build has no codec';
      }

      final loop = CallLoop(codec: codec, connection: connection);
      _loop = loop;

      // Announced, even though the phase has not changed.
      //
      // Whatever is on screen is handed `loop` when it is built, and it is
      // built the moment the call reaches `talking`, which happens in `answer`
      // and in `_arrived` **before** this runs. Without this the screen holds
      // the null it was built with for the life of the call: the duration and
      // the quality line still work, because they come from the state, and the
      // keypad silently does nothing, because it is the only control that
      // needs the loop itself.
      _changes.add(_state);

      await loop.start();

      // Here rather than when the other side answered, because answering is
      // not the same event as being through: everything between the two is
      // where calls were failing, and a tone that plays before the media
      // connection exists says the wrong thing confidently.
      unawaited(playTone('connected'));
      return null;
    } on Object catch (e) {
      hangUp(CallEnded.lost);
      return '$e';
    }
  }

  /// Poll for the caller rather than blocking.
  ///
  /// A blocking accept stops the isolate, and on a phone that is the thread
  /// drawing the interface. Polled in quarter second slices, the ring keeps
  /// animating while this waits.
  /// Wait for the caller to arrive, in slices rather than in one wait.
  ///
  /// Ten seconds altogether, which is a caller's patience, taken a second at a
  /// time so a call the person cancels stops within a second rather than
  /// holding the isolate to the end.
  ///
  /// A second rather than the quarter it was. Each slice that expires abandons
  /// an accept that may be part way through a handshake, and what it abandoned
  /// is gone: the far side completed, this side started again from nothing. A
  /// quarter of a second is inside the range a relayed handshake takes, so the
  /// window was being closed on connections that were most of the way in.
  Future<RotelyxConnection?> _waitForPeer(RotelyxEndpoint endpoint) async {
    for (var i = 0; i < 10; i++) {
      final connection =
          endpoint.accept(timeout: const Duration(seconds: 1));
      if (connection != null) return connection;
      if (!_state.isBusy) return null;
      await Future<void>.delayed(Duration.zero);
    }
    return null;
  }

  /// The reason the last `_bind` failed, or null.
  ///
  /// It used to be thrown away. `openEndpoint` reports which of four things
  /// went wrong, and every one of them surfaced as "this build cannot open a
  /// connection for calls", which names the build and says nothing about the
  /// failure. On a phone that is the only diagnosis anybody gets.
  String? _bindFailure;

  RotelyxEndpoint? _bind() {
    if (_endpoint != null) return _endpoint;
    try {
      _bindFailure = null;
      final endpoint = openEndpoint(
        identityHex: store.transportIdentity,
        relay: rotelyxConfig.relay,
      );
      if (endpoint == null) {
        // Null and an exception are different failures. This one is a library
        // without the transport symbols, which is a build to replace rather
        // than anything the person holding the phone can act on, and saying so
        // is the difference between that and a relay it could not reach.
        _bindFailure = transportIsBuilt
            ? 'the engine has the transport and would not open it'
            : 'this build of the engine has no transport';
        return null;
      }
      return _endpoint = endpoint;
    } on NetRefused catch (e) {
      _bindFailure = e.message;
      return null;
    }
  }

  /// Give up on a call nobody answered.
  void _watch() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_state.isBusy) {
        _watchdog?.cancel();
        return;
      }
      if (_state.ringingTooLong()) hangUp(CallEnded.unanswered);
    });
  }

  /// Back to nothing, after the screen has had time to say how it ended.
  void _clearLater() {
    Timer(const Duration(seconds: 3), () {
      if (_state.phase == CallPhase.over) _move(_state.cleared);
    });
  }

  void _teardown() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _watchdog?.cancel();
    _watchdog = null;
    _theirAddress = null;

    final loop = _loop;
    _loop = null;
    unawaited(loop?.stop() ?? Future<void>.value());
  }

  /// On only under `--dart-define=ROTELYX_CALL_DIAG=true`.
  ///
  /// The setting up of a call is the part with no sound to listen to and no
  /// counter to read: an address is minted on one side, travels through the
  /// mailbox, and is dialled on the other, and if any of that is wrong the
  /// only symptom is a call that runs with nothing coming out of it.
  static const _diag =
      bool.fromEnvironment('ROTELYX_CALL_DIAG', defaultValue: false);

  void _say(String what) {
    if (_diag) debugPrint('ROTELYX_CALL $what');
  }

  void _move(CallState next) {
    _state = next;
    _changes.add(next);
  }
}

/// The one this application uses.
final Calls calls = Calls.instance;
