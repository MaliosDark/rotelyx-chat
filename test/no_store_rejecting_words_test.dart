/// Fails the build if a word that gets an app rejected reaches the screen.
///
/// # Why this exists
///
/// Two kinds of wording cost a review, and both were in the shipped strings.
///
/// A release-stage label. "pre-release" sat in the settings note, in a chip
/// beside the name, and in the pairing screen. A store reads that as an
/// unfinished product and refuses it, and the word was never carrying the
/// meaning anyway: what those notes had to say is that nobody outside the
/// project has audited the cryptography, which is a different statement and
/// survives here.
///
/// And naming the platforms. The ongoing notification said the connection
/// existed so that "Firebase or Apple" would not be told a message arrived,
/// and the channel description said the same about "Google or Apple". The
/// property is real and it is in the threat model, but a permanent
/// notification that names the reviewer's own service in the negative is an
/// argument, not a description, and the person reading it wanted to know why
/// their phone is holding a connection.
///
/// Comments are exempt, because the reasoning has to live somewhere and this
/// file is not an argument for pretending otherwise. Only text that can reach
/// a screen is checked.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Words a store reads as "this application is not finished".
const stageWords = <String>[
  'pre-release',
  'prerelease',
  'beta',
  'alpha build',
  'demo',
  'test build',
  'trial version',
  'work in progress',
];

/// Named in the negative, these read as a complaint rather than a description.
const platformNames = <String>['Firebase', 'Google', 'Apple'];

/// Files whose strings a person can end up reading.
final surfaces = <String>[
  ...Directory('lib/ui').listSync(recursive: true).whereType<File>().map((f) => f.path).where((p) => p.endsWith('.dart')),
  'lib/rotelyx/push.dart',
  'android/app/src/main/kotlin/com/rotelyx/app/Notifications.kt',
  'android/app/src/main/kotlin/com/rotelyx/app/ConnectionService.kt',
];

/// Every quoted string, with comment lines removed first.
List<String> literals(String source) {
  final code = source
      .split('\n')
      .where((line) {
        final t = line.trimLeft();
        return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
      })
      .join('\n');

  // Two patterns rather than one: a Dart raw string cannot escape its own
  // delimiter, so each quote style is matched by a literal delimited with the
  // other one.
  final single = RegExp(r"'([^'\\\n]|\\.)*'");
  final double = RegExp('"([^"\\\\\\n]|\\\\.)*"');

  return [
    ...single.allMatches(code).map((m) => m.group(0)!),
    ...double.allMatches(code).map((m) => m.group(0)!),
  ];
}

void main() {
  test('nothing on screen calls this an unfinished build', () {
    final found = <String>[];

    for (final path in surfaces) {
      final file = File(path);
      if (!file.existsSync()) continue;
      for (final text in literals(file.readAsStringSync())) {
        final lower = text.toLowerCase();
        for (final word in stageWords) {
          if (lower.contains(word)) found.add('$path: $text');
        }
      }
    }

    expect(
      found,
      isEmpty,
      reason: 'A store reads these as an unfinished product and refuses it. '
          'Say what is actually true instead: "has not been independently '
          'audited" is a real statement and costs nothing.\n${found.join('\n')}',
    );
  });

  test('the ongoing notification describes itself without naming a platform',
      () {
    final found = <String>[];

    for (final path in const [
      'android/app/src/main/kotlin/com/rotelyx/app/Notifications.kt',
      'android/app/src/main/kotlin/com/rotelyx/app/ConnectionService.kt',
    ]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      for (final text in literals(file.readAsStringSync())) {
        for (final name in platformNames) {
          if (text.contains(name)) found.add('$path: $text');
        }
      }
    }

    expect(
      found,
      isEmpty,
      reason: 'The notification a person cannot dismiss is the wrong place to '
          'argue about anybody else\'s service. Say what this one does for '
          'them.\n${found.join('\n')}',
    );
  });
}
