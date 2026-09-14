import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('rotelyx/trace');

/// To the platform's log through the host, and to standard error as well.
///
/// Android drops Dart's own output on some phones (`log.tag=E` on the one this
/// was written for), so the host writes the line at error level, which is the
/// one level nothing filters. Desktop has no host and standard error is fine.
void trace(String line) {
  stderr.writeln('[rotelyx] $line');
  if (Platform.isAndroid || Platform.isIOS) {
    _channel.invokeMethod<void>('line', line).catchError((_) {});
  }
}
