/// Notifications in a browser.
///
/// The Notification API is part of the browser and reaches nothing: a page that
/// is open and has been granted permission draws its own. No push service, no
/// subscription, no endpoint, and nothing registered anywhere.
///
/// The Push API would be the other option and is deliberately not used. It
/// requires a push endpoint, which for Chrome is Google's and for Firefox is
/// Mozilla's, and it would tell that service the same thing Firebase would: an
/// install received something at a time. A tab that is open does not need it,
/// and a tab that is closed is not running, which is the honest limit of a
/// browser and is stated rather than papered over.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'notify_api.dart';

export 'notify_api.dart';

class PlatformNotifier implements Notifier {
  const PlatformNotifier();

  @override
  Future<bool> permitted() async => web.Notification.permission == 'granted';

  @override
  Future<bool> request() async {
    if (web.Notification.permission == 'denied') return false;
    final result = await web.Notification.requestPermission().toDart;
    return result.toDart == 'granted';
  }

  @override
  Future<void> show(Notice notice) async {
    if (!await permitted()) return;

    final options = web.NotificationOptions(
      body: notice.showContent ? notice.body : 'New message',
      // One per conversation, replacing rather than stacking.
      tag: notice.conversationId,
      silent: notice.silent,
      icon: _icon(notice.picture),
    );

    _showing[notice.conversationId] = web.Notification(notice.sender, options);
  }

  @override
  Future<void> clear(String conversationId) async {
    _showing.remove(conversationId)?.close();
  }

  /// A tab that is closed is not running. There is no equivalent of a
  /// foreground service in a browser, and the Push API, which would be the
  /// substitute, routes through Google's or Mozilla's endpoint and tells it
  /// the same thing Firebase would.
  @override
  bool get canStayConnected => false;

  @override
  Future<bool> connect() async => false;

  @override
  Future<void> disconnect() async {}

  /// Held so a read conversation can take its own notification down. The
  /// browser has no other handle on one it has already shown.
  static final Map<String, web.Notification> _showing = {};

  /// A data URL, because there is nowhere to fetch a picture from and nothing
  /// should be fetched. The brand mark when they have not sent one.
  static String _icon(Uint8List? picture) {
    if (picture == null) return 'assets/assets/images/rotelyx-mark.png';
    return 'data:image/png;base64,${_base64(picture)}';
  }

  static String _base64(Uint8List bytes) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final out = StringBuffer();
    for (var i = 0; i < bytes.length; i += 3) {
      final b0 = bytes[i];
      final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out.write(alphabet[b0 >> 2]);
      out.write(alphabet[((b0 & 0x03) << 4) | (b1 >> 4)]);
      out.write(i + 1 < bytes.length
          ? alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)]
          : '=');
      out.write(i + 2 < bytes.length ? alphabet[b2 & 0x3f] : '=');
    }
    return out.toString();
  }
}
