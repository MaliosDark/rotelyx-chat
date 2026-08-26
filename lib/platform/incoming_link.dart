/// Invitation links arriving from outside the application.
///
/// Two ways in, because there are two situations. A link tapped while this is
/// closed starts it, and the link is waiting before any of this exists: that
/// one is asked for, once, with [initialLink]. A link tapped while it is
/// running is pushed, and arrives on [incomingLinks].
///
/// Answering only the second would lose every invitation that reaches a phone
/// where the application was not already open, which is most of them.
library;

import 'dart:async';

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('rotelyx/links');

final _links = StreamController<String>.broadcast();

/// Links arriving while the application is up.
Stream<String> get incomingLinks => _links.stream;

var _listening = false;

/// The link this launch was started by, or null. Answers once: a second call
/// returns null even if the first found something.
Future<String?> initialLink() async {
  _listen();
  try {
    return await _channel.invokeMethod<String>('initial');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    // No implementation on this platform, which is every platform but Android
    // today. Not a failure and nothing to report.
    return null;
  }
}

void _listen() {
  if (_listening) return;
  _listening = true;

  _channel.setMethodCallHandler((call) async {
    if (call.method != 'link') return null;
    final link = call.arguments;
    if (link is String && link.isNotEmpty) _links.add(link);
    return null;
  });
}
