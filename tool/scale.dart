/// What a group actually costs as it grows.
///
///     LD_LIBRARY_PATH=build/native dart run tool/scale.dart [max]
///
/// # What this measures and what it does not
///
/// Nothing here touches a network. Every member is a session in this one
/// process, which is exactly right for the first question: whether the protocol
/// holds a thousand people at all, and what one message costs when it does.
/// A thousand phones would answer the same question much later and much worse.
///
/// The number that decides everything is envelopes per message. `sealForGroup`
/// returns one envelope per recipient, so a group of a thousand turns a single
/// sentence into nine hundred and ninety nine deposits at the mailbox. The
/// cryptography is not what breaks first.
library;

import 'dart:io';

import 'package:rotelyx_chat/rotelyx/engine/api.dart';
import 'package:rotelyx_chat/rotelyx/engine/native.dart';

String bytes(int n) => n >= 1048576
    ? '${(n / 1048576).toStringAsFixed(1)} MB'
    : n >= 1024
        ? '${(n / 1024).toStringAsFixed(0)} kB'
        : '$n B';

Future<void> main(List<String> args) async {
  final ceiling = args.isEmpty ? 1000 : int.parse(args.first);
  final engine = createEngine();

  stdout.writeln('engine reports maxMembers = ${engine.maxMembers}');
  stdout.writeln();

  final host = engine.newSession('host');
  host.found();

  final guests = <RotelyxSession>[];
  final marks = <int>[2, 10, 50, 100, 250, 500, 750, 1000]
      .where((m) => m <= ceiling)
      .toList();

  stdout.writeln('${'members'.padLeft(8)}  ${'add one'.padLeft(9)}  '
      '${'envelopes'.padLeft(10)}  ${'per message'.padLeft(12)}  '
      '${'rss'.padLeft(8)}');

  var next = 0;
  for (final target in marks) {
    final addStart = DateTime.now();

    while (host.memberCount < target) {
      final guest = engine.newSession('guest${next++}');
      try {
        final invitation = host.invite(guest.keyPackage());
        guest.join(invitation.welcome, invitation.ratchetTree);
        guests.add(guest);
      } on Object catch (e) {
        stdout.writeln();
        stdout.writeln('STOPPED at ${host.memberCount} members: $e');
        stdout.writeln('That is the real ceiling, whatever the constant says.');
        exit(1);
      }
    }

    final added = DateTime.now().difference(addStart);
    final perAdd = host.memberCount <= 2
        ? added
        : Duration(
            microseconds: added.inMicroseconds ~/ (target - (marks.indexOf(target) == 0 ? 1 : marks[marks.indexOf(target) - 1])));

    // One ordinary sentence, sealed for everybody.
    final sendStart = DateTime.now();
    final envelopes = host.sealForGroup(host.send('an ordinary message'));
    final sealed = DateTime.now().difference(sendStart);

    final total = envelopes.fold<int>(0, (a, e) => a + e.length);

    stdout.writeln(
      '${host.memberCount.toString().padLeft(8)}  '
      '${'${perAdd.inMilliseconds} ms'.padLeft(9)}  '
      '${envelopes.length.toString().padLeft(10)}  '
      '${'${bytes(total)} / ${sealed.inMilliseconds}ms'.padLeft(12)}  '
      '${bytes(ProcessInfo.currentRss).padLeft(8)}',
    );
  }

  stdout.writeln();
  stdout.writeln('safety number still agrees across the group: '
      '${guests.isEmpty || guests.last.safetyNumber() == host.safetyNumber()}');

  final perMessage = host.sealForGroup(host.send('x'));
  stdout.writeln();
  stdout.writeln('At ${host.memberCount} members, one message is '
      '${perMessage.length} deposits totalling '
      '${bytes(perMessage.fold<int>(0, (a, e) => a + e.length))}.');
  stdout.writeln('Ten people saying one thing each is '
      '${perMessage.length * 10} deposits.');

  host.dispose();
  for (final g in guests) {
    g.dispose();
  }
}
