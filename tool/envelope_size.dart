/// What one envelope weighs, and what it weighs a thousand times.
library;

import 'dart:io';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';

void main() {
  final engine = createEngine();
  final host = engine.newSession('host');
  host.found();

  final guest = engine.newSession('guest');
  final inv = host.invite(guest.keyPackage());
  guest.join(inv.welcome, inv.ratchetTree);

  stdout.writeln('${'message'.padLeft(10)}  ${'ciphertext'.padLeft(11)}  '
      '${'one envelope'.padLeft(13)}  ${'x999'.padLeft(9)}');

  for (final n in [1, 20, 100, 500, 1000, 4000]) {
    final text = 'x' * n;
    final ciphertext = host.send(text);
    final envelopes = host.sealForGroup(ciphertext);
    final one = envelopes.first.length;

    stdout.writeln(
      '${'$n B'.padLeft(10)}  '
      '${'${ciphertext.length} B'.padLeft(11)}  '
      '${'$one B'.padLeft(13)}  '
      '${'${(one * 999 / 1048576).toStringAsFixed(2)} MB'.padLeft(9)}',
    );
  }

  stdout.writeln();
  final typical = host.sealForGroup(host.send('sounds good, see you at eight'));
  final each = typical.first.length;
  stdout.writeln('A typical short message is ${each} B per recipient.');
  stdout.writeln();
  stdout.writeln('In a group of 1000, one such message costs the sender '
      '${(each * 999 / 1048576).toStringAsFixed(2)} MB.');
  stdout.writeln('A hundred messages in a day: '
      '${(each * 999 * 100 / 1048576).toStringAsFixed(0)} MB uploaded by the '
      'people sending them.');
  stdout.writeln('And each of the other 999 downloads only their own copy: '
      '${(each * 100 / 1024).toStringAsFixed(0)} kB.');

  host.dispose();
  guest.dispose();
}
