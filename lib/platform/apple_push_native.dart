/// Asking iOS for a push token, through the method channel in AppDelegate.swift.
library;

import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/services.dart';

import '../rotelyx/push.dart';

const MethodChannel _channel = MethodChannel('rotelyx/apple-push');

/// Register with Apple and wait for the token.
///
/// The registration itself is asynchronous inside iOS: `registerForRemote
/// Notifications` returns immediately and the token arrives later in a delegate
/// callback. The Swift side holds it and answers this call when it has one, so
/// Dart sees one await rather than a callback it has to survive.
Future<String?> applePushToken() async {
  if (!Platform.isIOS) return null;
  try {
    return await _channel.invokeMethod<String>('token');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    // An iOS build from before the AppDelegate was wired. Better than a crash.
    return null;
  }
}

/// Where the conversation log should live.
///
/// On iOS this is the App Group container shared with the notification
/// extension, because two processes with two sandboxes cannot otherwise see one
/// file. Null everywhere else, and null on an iOS build whose provisioning
/// profile does not carry the App Group, in which case storage falls back to
/// this application's own container: history still works and only the
/// extension loses its view of it.
Future<String?> sharedContainerPath() async {
  if (!Platform.isIOS) return null;
  try {
    return await _channel.invokeMethod<String>('container');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Android holds its own connection and needs nobody to wake it. iOS cannot,
/// so it uses Apple and says so in Settings.
PushTransport pushForThisPlatform() =>
    Platform.isIOS ? const ApnsPush() : const NoPush();

/// Leave the tags being listened on where the notification extension can read
/// them.
///
/// # Why the extension is told anything at all
///
/// A push carries nothing, on purpose: a payload with the message in it is a
/// message handed to Apple. So the extension has to find out for itself
/// whether anything actually arrived, and to ask the mailbox that, it has to
/// be able to name the tags.
///
/// Without this it cannot ask and has to guess, and the only guess available
/// is "show something for every wake". The mailbox wakes on a schedule whether
/// or not anything arrived, so that guess is a notification every few minutes
/// that says nothing.
///
/// # What is written
///
/// The mailbox URL and the tags, which is what the mailbox already sees on
/// every subscription this application makes. No key, no message, no name.
/// The file lives in the App Group container, which only this application and
/// its own extension can open.
Future<void> publishListeningTags(String mailbox, List<String> tags) async {
  if (!Platform.isIOS) return;
  final path = await sharedContainerPath();
  if (path == null) return;
  await File('$path/listening.json')
      .writeAsString(jsonEncode({'mailbox': mailbox, 'tags': tags}));
}

/// What the last push wake did, as the extension left it.
///
/// Null on anything but iOS, and null until a wake has happened at all.
///
/// # Why the application reads its own extension's notes
///
/// A notification extension runs for seconds in a process nobody is watching
/// and then dies. When one shows the wrong thing there is nothing to look at
/// afterwards, and working out why turns into two people guessing. This is the
/// note it leaves, shown in Settings, so the question has an answer that can
/// be read out loud.
Future<LastWake?> lastWake() async {
  if (!Platform.isIOS) return null;
  final path = await sharedContainerPath();
  if (path == null) return null;

  try {
    final file = File('$path/last-wake.json');
    if (!file.existsSync()) return null;
    final row = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final at = row['at'];
    if (at is! num) return null;
    return LastWake(
      at: DateTime.fromMillisecondsSinceEpoch(at.round()),
      decoy: row['decoy'] == true,
      waiting: row['waiting'] as int?,
      ending: row['ending'] as String? ?? 'unknown',
    );
  } on Object {
    return null;
  }
}

/// One line about the last time a push woke this phone.
///
/// Deliberately nothing about who or what: this is a note about plumbing.
class LastWake {
  const LastWake({
    required this.at,
    required this.decoy,
    required this.waiting,
    required this.ending,
  });

  final DateTime at;

  /// Whether the server said this wake might find nothing, which is what a
  /// scheduled sweep says and what a ticket does not.
  final bool decoy;

  /// What the mailbox answered, or null when it could not be asked.
  final int? waiting;

  /// One of `ticket`, `waiting`, `nothing`, `unknown`, `expired`.
  final String ending;

  /// What happened, in a sentence somebody can act on.
  String get said => switch (ending) {
        'ticket' => 'A message arrived and was shown.',
        'waiting' =>
          'The mailbox held ${waiting == 1 ? 'a message' : '$waiting messages'}, and it was shown.',
        'nothing' => 'A scheduled wake found nothing, and showed a blank.',
        'unknown' =>
          'A scheduled wake could not reach the mailbox, and showed a blank.',
        'expired' => 'A wake ran out of time and showed what the server sent.',
        _ => 'A wake happened.',
      };

  /// Whether this is one of the endings that puts a blank on the screen.
  bool get wasBlank => ending == 'nothing' || ending == 'unknown';
}
