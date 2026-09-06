/// The watch, answered from the phone.
///
/// # Why the questions come here rather than to the mailbox
///
/// The watch holds no key and no session, so it cannot open a message or send
/// one. It asks this application, which has both, and shows what comes back.
/// That is the whole of the design: another screen onto a conversation that
/// lives in one place.
///
/// `ios/Runner/WatchBridge.swift` carries the questions across and translates
/// nothing. What each one means is decided here.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../rotelyx/chosen_name.dart';
import '../rotelyx/ephemeral.dart';
import '../rotelyx/meeting_code.dart';
import '../rotelyx/qr_matrix.dart';
import '../rotelyx/quoted.dart';
import '../rotelyx/rotelyx_service.dart';
import '../rotelyx/rotelyx_store.dart';
import '../rotelyx/rotelyx_wasm.dart';
import 'watch_api.dart';

export 'watch_api.dart';

const MethodChannel _channel = MethodChannel('rotelyx/watch');

/// How many conversations and how many messages within one the watch is given.
///
/// A watch shows a handful of lines and is read at arm's length, so sending
/// more is battery spent on a screen nobody scrolls. It is also a bound on
/// what a stolen watch could hold.
const _conversations = 12;
const _messages = 20;

class PlatformWatch implements Watch {
  PlatformWatch();

  bool get _wired => Platform.isIOS;

  /// The pairing the watch asked for, while it is still waiting.
  ///
  /// Held so that the conversation is recorded when the other side arrives.
  /// The pairing screen does that for a pairing started on the phone, and there
  /// is no screen here: without this the handshake would complete, the session
  /// would be live, and nothing would exist in the list afterwards.
  StreamSubscription<RotelyxState>? _waiting;
  String? _made;

  @override
  void listen() {
    if (!_wired) return;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'conversations':
          return _conversationList();
        case 'messages':
          return _transcript(call.arguments as String?);
        case 'send':
          return _send(call.arguments as Map?);
        case 'code':
          return _code();
        case 'codeStop':
          return _codeStop();
        default:
          throw MissingPluginException('the watch asked for ${call.method}');
      }
    });
  }

  @override
  void arrived({bool silent = false}) =>
      _tell({'arrived': true, 'silent': silent});

  @override
  void paired() => _tell({'paired': true});

  /// Push something to the watch, if one is there.
  ///
  /// Failures are dropped. There is no watch on most phones, the watch that
  /// exists is asleep most of the time, and neither is a thing to report.
  void _tell(Map<String, Object?> what) {
    if (!_wired) return;
    _channel.invokeMethod<void>('notify', what).catchError((_) {});
  }

  /// Enough to draw a list: who, when, and the last thing said.
  Map<String, Object?> _conversationList() {
    final all = store.loadAll()
      ..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));

    return {
      // What the complication is allowed to show, decided here rather than on
      // the watch. The watch draws what it is given, so a setting enforced at
      // this end is a setting the watch cannot get wrong, and what is refused
      // is never written to the watch at all rather than written and hidden.
      //
      // `hasUnread` rather than a number of our own: it is derived from when a
      // conversation was last opened rather than incremented on arrival, and a
      // face is the worst place for a badge that can drift. Counted over every
      // conversation, not the twelve sent below, because a count that quietly
      // stops at twelve is a wrong count.
      'waiting': store.faceDetail == FaceDetail.nothing
          ? 0
          : all.where((c) => c.hasUnread).length,
      'who': store.faceDetail == FaceDetail.name
          ? (all.where((c) => c.hasUnread).firstOrNull?.displayTitle ?? '')
          : '',
      'conversations': [
        for (final c in all.take(_conversations))
          {
            'id': c.id,
            'title': c.displayTitle,
            'last': c.messages.isEmpty ? '' : c.messages.last.text,
            'at': c.lastActivity.millisecondsSinceEpoch,
          }
      ],
    };
  }

  /// The recent end of one conversation.
  ///
  /// A conversation under its own PIN is not sent. The watch has no way to ask
  /// for one and no screen to type it on, and a lock that a second screen walks
  /// around is not a lock.
  Map<String, Object?> _transcript(String? id) {
    if (id == null) return {'error': 'no conversation'};
    if (store.isLocked(id) && !store.isOpened(id)) {
      return {'locked': true};
    }

    final conversation = store.load(id);
    if (conversation == null) return {'error': 'no conversation'};

    // Gone here is gone there.
    //
    // The whole list used to go across, `burnt` and all, so a message this
    // phone had already destroyed carried on being readable on the wrist. An
    // expiring message that survives on a second screen is the exact failure
    // the feature exists to prevent, and it is worse than never having sent it
    // to the watch: the person believes it is gone.
    final alive = conversation.messages.where((m) => !m.burnt).toList();

    final recent = alive.length <= _messages
        ? alive
        : alive.sublist(alive.length - _messages);

    return {
      'title': conversation.displayTitle,
      'messages': [
        for (final m in recent)
          {
            // Unwrapped, in the order it was wrapped, so a quoted reply that
            // also expires reads as what somebody wrote. The raw text went
            // across before this, markers and all, and the watch drew the
            // envelope as though it were the letter.
            'text': Quoted.plain(Ephemeral.plain(m.text)),
            'mine': m.mine,
            'at': m.at.millisecondsSinceEpoch,

            // When it goes, so the watch can burn it on time rather than
            // waiting to be told. Absent when nothing is counting.
            'burnAt': m.burnAt?.millisecondsSinceEpoch,

            // Whether it goes at all, which is not the same question. An
            // expiring message that nobody has read yet has no deadline set,
            // and the watch should still mark it: the flame is a warning about
            // what the message is, not a report of a clock already running.
            'burns': m.burnAt != null || Ephemeral.isEphemeral(m.text),
          }
      ],
    };
  }

  /// Say something from the wrist.
  ///
  /// Refused unless the conversation asked for is the live one, for the reason
  /// `chat.dart` refuses it too: acting on a session that belongs to another
  /// conversation sends the words to whoever that is.
  Future<Map<String, Object?>> _send(Map? args) async {
    final id = args?['id'] as String?;
    final text = (args?['text'] as String?)?.trim() ?? '';
    if (id == null || text.isEmpty) return {'error': 'nothing to send'};

    if (rotelyx.state != RotelyxState.joined || rotelyx.conversationId != id) {
      final resumed = await rotelyx.resume(id);
      if (!resumed) return {'error': 'that conversation is not connected'};
    }

    // `send` answers whether it went, rather than a future: it hands the
    // envelope to the mailbox client and the delivery arrives later as a state
    // change. False here is a refusal, not a failure in flight.
    try {
      return rotelyx.send(text)
          ? {'sent': true}
          : {'error': 'that message was not accepted'};
    } on Object catch (e) {
      return {'error': '$e'};
    }
  }

  // ---------------------------------------------------------------------------
  // Meeting somebody, with the phone in a pocket
  // ---------------------------------------------------------------------------

  /// Mint a meeting code, start waiting at the place it names, and hand the
  /// watch the symbol to draw.
  ///
  /// # Why the watch may show this without holding anything
  ///
  /// A meeting code is public. It is 120 random bits naming a place to meet,
  /// and `lib/rotelyx/meeting_code.dart` says what it is worth: it authenticates
  /// nobody, it lives for one handshake, and the safety number is still the
  /// only check that matters. So a screen showing one is a screen showing a
  /// public number, which is a thing a watch can do.
  ///
  /// The handshake itself happens here. The phone mints, the phone waits, the
  /// phone holds the keys, and the conversation is on the phone before the
  /// watch has finished animating. The watch contributed a surface to point a
  /// camera at, which is the whole of what it is for.
  Future<Map<String, Object?>> _code() async {
    // Somebody already waiting somewhere else is somebody whose scan would
    // arrive at the wrong place. Better to say so than to show a code that
    // silently cannot work.
    if (rotelyx.state == RotelyxState.joined) {
      return {'error': 'A conversation is open on your phone. Close it first.'};
    }

    final code = newMeetingCode();

    try {
      await RotelyxWasm.whenReady();

      // Remembered if there is one, invented if there is not. A watch is not a
      // place to type a name, and stopping the meeting to ask for one would
      // make this feature useless in the moment it exists for.
      final name = store.myName ?? suggestName();
      store.myName = name;

      await _codeStop();
      _waiting = rotelyx.stateChanges.listen(_paired);

      await rotelyx.pairByMeetingCode(
        code: code,
        displayName: name,
        role: PairingRole.host,
      );
    } on Object catch (e) {
      await _codeStop();
      return {'error': '$e'};
    }

    return {
      'code': prettyMeetingCode(code),
      'rows': qrRows(code),
    };
  }

  /// The watch left the screen. Stop listening; the pairing itself is left
  /// alone, because a scan already in flight is not the watch's to cancel.
  Future<Map<String, Object?>> _codeStop() async {
    await _waiting?.cancel();
    _waiting = null;
    _made = null;
    return {'ok': true};
  }

  /// Somebody scanned it. Write the conversation down.
  ///
  /// Guarded the way the pairing screen is guarded, and for the same reason:
  /// `joined` is a state and the stream says it more than once, so without this
  /// one scan would leave several empty conversations behind it.
  void _paired(RotelyxState state) {
    if (state != RotelyxState.joined || _made != null) return;

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    _made = id;

    store.save(StoredConversation(
      id: id,
      title: rotelyx.conversationName ?? 'Conversation',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));
    rotelyx.persistTo(id);
    paired();

    _waiting?.cancel();
    _waiting = null;
  }
}
