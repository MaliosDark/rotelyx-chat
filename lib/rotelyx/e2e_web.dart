/// A handle on the real service, for driving it from outside the canvas.
///
/// # The gap this closes
///
/// `tool/e2e/pair.js` mirrors the handshake step for step and proves the wasm
/// bridge and the protocol work. What it cannot prove is that
/// `RotelyxService` works, because it is not that code: it is a second
/// implementation that happens to agree with the first. The two could drift
/// tomorrow and every check would still pass.
///
/// The widget-level test would close it and needs Chrome and a driver that has
/// never produced a verdict in this environment. This is the other way in.
/// CanvasKit draws the whole application into one canvas, so there is nothing
/// in the DOM to click, but there is no rule that a test has to click: the
/// service is a plain object, and handing it to JavaScript lets a driver
/// exercise the same methods the buttons call.
///
/// # Why this is safe to have in the tree
///
/// [installE2eHook] is called only when `--dart-define=e2e=true` is passed, and
/// `bool.fromEnvironment` is resolved at compile time. A release build has no
/// branch that reaches it and the tree shaker removes the whole file. The same
/// mechanism as the screenshot fixtures in `lib/ui/app.dart`.
///
/// If that guard is ever weakened, this becomes a remote control for somebody
/// else's conversations. It is one line and it is the only thing standing
/// between the two, which is why it is stated here rather than assumed.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'ephemeral.dart';
import 'meeting_code.dart';
import 'rotelyx_service.dart';
import 'rotelyx_store.dart';

/// Whether the hook is compiled in at all.
const e2eEnabled = bool.fromEnvironment('e2e');

@JS('window')
external JSObject get _window;

/// Whether this page is somewhere a driver could plausibly be running.
///
/// The compile-time flag is one flag on one command line, and what it opens is
/// total: anything running in the page can drive the account, read the inbox
/// and pair with a stranger. An audit called the containment real and the blast
/// radius total, which is the shape that wants a second condition rather than
/// more care.
///
/// So the hook also refuses to install anywhere but a loopback origin. A build
/// that shipped with the flag by mistake still publishes nothing on a real
/// host, and the driver, which runs against a local server, is unaffected.
bool get _onADriverOrigin {
  final host = _location.getProperty('hostname'.toJS)?.toString() ?? '';
  return host == 'localhost' || host == '127.0.0.1' || host == '[::1]';
}

@JS('location')
external JSObject get _location;

/// Publish the service as `window.__rotelyx`.
///
/// Does nothing unless the build was given `--dart-define=e2e=true` **and** the
/// page is on a loopback origin.
void installE2eHook() {
  if (!e2eEnabled) return;
  if (!_onADriverOrigin) return;

  final received = <String>[];
  rotelyx.messages.listen((m) {
    if (!m.mine) received.add(m.text);
  });

  // A plain object with function properties, built rather than declared. An
  // extension type with an `external factory` would compile and then fail at
  // runtime with "not a constructor", because that form names a JavaScript
  // class, and there is no class here to name.
  final hook = JSObject();

  hook['newCode'] = (() => newMeetingCode().toJS).toJS;

  hook['host'] = ((JSString code, JSString name) {
    rotelyx.pairByMeetingCode(
      code: code.toDart,
      displayName: name.toDart,
      role: PairingRole.host,
    );
  }).toJS;

  hook['join'] = ((JSString code, JSString name) {
    rotelyx.pairByMeetingCode(
      code: code.toDart,
      displayName: name.toDart,
      role: PairingRole.guest,
    );
  }).toJS;

  hook['send'] = ((JSString text) => rotelyx.send(text.toDart).toJS).toJS;

  // A message with a timer on it, and the reading that starts it. Both go
  // through the same calls the composer and the conversation screen make, so
  // what this drives is the feature rather than an imitation of it.
  hook['sendBurning'] = ((JSString text, JSNumber seconds) => rotelyx
      .send(Ephemeral.wrap(seconds: seconds.toDartInt, body: text.toDart)
          .encode())
      .toJS).toJS;

  hook['read'] = ((JSString conversationId) =>
      rotelyx.markBurnRead(conversationId.toDart).toJS).toJS;

  /// Create the conversation record, the way the pairing screen does once the
  /// group exists. Without it nothing this side sends is written down, so
  /// there is no copy for a read acknowledgement to start a clock on.
  hook['persist'] = (() {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    store.save(StoredConversation(
      id: id,
      title: rotelyx.conversationName ?? 'Conversation',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));
    rotelyx.persistTo(id);
    return id.toJS;
  }).toJS;

  hook['conversation'] = (() => (rotelyx.conversationId ?? '').toJS).toJS;

  /// Every expiring message, as "id:mine:millisecondsLeft", so a driver can
  /// measure the gap between two clocks that started from the same event.
  /// Milliseconds rather than seconds because the gap being measured is
  /// smaller than a second, and a whole-second reading would report it as
  /// either nothing or twice what it is.
  hook['burning'] = (() {
    final id = rotelyx.conversationId;
    final c = id == null ? null : store.load(id);
    final out = <String>[
      for (final m in c?.messages ?? const <StoredMessage>[])
        if (Ephemeral.isEphemeral(m.text))
          '${Ephemeral.idOf(m.text)}:${m.mine}:${m.burnIn?.inMilliseconds ?? -1}',
    ];
    return jsonEncode(out).toJS;
  }).toJS;

  // Everything below is a getter rather than a value, so the driver reads the
  // service as it is now rather than as it was when the hook was installed.
  hook['state'] = (() => rotelyx.state.name.toJS).toJS;
  hook['safety'] = (() => (rotelyx.safetyNumber ?? '').toJS).toJS;
  hook['epoch'] = (() => rotelyx.epoch.toJS).toJS;
  hook['members'] = (() => rotelyx.memberCount.toJS).toJS;
  hook['inbox'] = (() => jsonEncode(received).toJS).toJS;
  hook['lastError'] = (() => (rotelyx.lastError ?? '').toJS).toJS;

  _window['__rotelyx'] = hook;
}
