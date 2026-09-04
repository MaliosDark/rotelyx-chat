/// Notifications on a phone, through this application's own channel.
///
/// The work is in `android/app/src/main/kotlin/.../Notifications.kt`. This is
/// the wire to it, and nothing more: no logic lives on both sides.
///
/// iOS answers two of these and not the rest, from `AppDelegate.swift`, and the
/// split is the platform limit rather than an omission. iOS does not permit a
/// background socket, so there is no moment at which this application could
/// decide to notify while it is not running: what shows a notification there is
/// the extension in `ios/NotificationService/`, when a push arrives.
///
/// So `show` and `clear` are Android's, and so are `connect` and `disconnect`,
/// which are the foreground service. `permitted` and `request` are both
/// platforms', because both have a permission and asking about it is the same
/// question. Returning false on iOS instead, which is what this did, made the
/// settings switch dead and told the person to change a setting they had never
/// been asked for.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'notify_api.dart';

export 'notify_api.dart';

const MethodChannel _channel = MethodChannel('rotelyx/notifications');

class PlatformNotifier implements Notifier {
  const PlatformNotifier();

  /// Whether this platform posts notifications from here.
  bool get _wired => Platform.isAndroid;

  /// Whether this platform has a notification permission to ask about. Both
  /// mobile ones do; only one of them posts.
  bool get _asks => Platform.isAndroid || Platform.isIOS;

  @override
  Future<bool> permitted() async {
    if (!_asks) return false;
    try {
      return await _channel.invokeMethod<bool>('permitted') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // An iOS build from before AppDelegate answered this channel. Treated as
      // "not permitted" rather than allowed to throw out of a settings screen.
      return false;
    }
  }

  @override
  Future<bool> request() async {
    if (!_asks) return false;
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> show(Notice notice) async {
    if (!_wired) return;
    try {
      await _channel.invokeMethod<void>('show', {
        // The channel carries integers, and a conversation id is a timestamp
        // in microseconds, which does not fit in one. Hashed rather than
        // truncated: two conversations created in the same second would share
        // a truncated id and replace each other's notifications.
        'id': _slot(notice.conversationId),
        'title': notice.sender,
        'body': notice.body,
        'picture': notice.picture,
        'showContent': notice.showContent,
        'silent': notice.silent,
      });
    } on PlatformException {
      // Refused permission, or a system that would not post it. The message is
      // in the conversation either way, so there is nothing to recover from.
    }
  }

  @override
  Future<void> clear(String conversationId) async {
    if (!_wired) return;
    try {
      await _channel.invokeMethod<void>('clear', {'id': _slot(conversationId)});
    } on PlatformException {
      // Nothing was showing.
    }
  }

  @override
  bool get canStayConnected => _wired;

  @override
  Future<bool> connect() async {
    if (!_wired) return false;
    try {
      return await _channel.invokeMethod<bool>('connect') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    if (!_wired) return;
    try {
      await _channel.invokeMethod<void>('disconnect');
    } on PlatformException {
      // Nothing was running.
    }
  }

  /// A stable positive 31 bit number for a conversation.
  static int _slot(String id) {
    var hash = 0;
    for (final unit in id.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }
}
