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
      return 'This build cannot open a connection for calls.';
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

    final next = _state.answer();
    if (next == null) return null;

    rotelyx.signal(Signal.call(CallSignal.answered, id: _state.id));
    _move(next);

    return _open(dialling: false);
  }

  /// End it, whatever it was doing.
  void hangUp(CallEnded why) {
    final id = _state.id;
    final next = _state.end(why);
    if (next == null) return;

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
        unawaited(_open(dialling: true));
      case CallPhase.over:
        _teardown();
        _clearLater();
      case CallPhase.idle:
      case CallPhase.ringingOut:
        break;
    }
  }

  /// Open the media path, once both sides have agreed.
  Future<String?> _open({required bool dialling}) async {
    final endpoint = _endpoint ?? _bind();
    if (endpoint == null) return 'no transport';

    final session = rotelyx.session;
    if (session == null) return 'the conversation is not open';

    try {
      final connection = dialling
          ? endpoint.connect(_theirAddress ?? '')
          : await _waitForPeer(endpoint);

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
      await loop.start();
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
  Future<RotelyxConnection?> _waitForPeer(RotelyxEndpoint endpoint) async {
    for (var i = 0; i < 40; i++) {
      final connection =
          endpoint.accept(timeout: const Duration(milliseconds: 250));
      if (connection != null) return connection;
      if (!_state.isBusy) return null;
      await Future<void>.delayed(Duration.zero);
    }
    return null;
  }

  RotelyxEndpoint? _bind() {
    if (_endpoint != null) return _endpoint;
    try {
      return _endpoint = openEndpoint(
        identityHex: store.transportIdentity,
        relay: rotelyxConfig.relay,
      );
    } on NetRefused {
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

  void _move(CallState next) {
    _state = next;
    _changes.add(next);
  }
}

/// The one this application uses.
final Calls calls = Calls.instance;
