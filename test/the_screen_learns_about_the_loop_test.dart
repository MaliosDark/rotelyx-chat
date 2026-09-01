/// Fails the build if the call loop is created without saying so.
///
/// # The defect this exists for
///
/// Whatever is on screen during a call is handed the `CallLoop`, and it is
/// handed it once, when it is built. It is built the moment the call reaches
/// `talking`, and that happens in `answer` and in `_arrived`, both of which
/// run **before** `_open` has created the loop. So the screen was built with
/// null and nothing ever rebuilt it.
///
/// Nothing looked wrong. The duration counted, the quality line appeared when
/// the connection struggled, and the call sounded normal, because all of that
/// comes from `CallState` rather than from the loop. Only the keypad needs the
/// loop itself, so the only symptom was a key that made no sound at the far
/// end, on one side of the call and not the other, depending on whether some
/// unrelated rebuild had happened to refresh the screen in between.
///
/// A control that does nothing when pressed reports nothing, which is why this
/// is checked here rather than left to be noticed.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/rotelyx/calls.dart').readAsStringSync();

  test('creating the loop publishes a change', () {
    // The assignment and the announcement, in that order, with only comments
    // and blank lines between them.
    final between = RegExp(
      r'_loop = loop;(.*?)_changes\.add\(',
      dotAll: true,
    ).firstMatch(source);

    expect(
      between,
      isNotNull,
      reason: 'Nothing announces the loop after it is created. The screen was '
          'built before this point and holds whatever it was given then, so a '
          'control that needs the loop will do nothing for the whole call.',
    );

    final gap = between!.group(1)!;
    final code = gap
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('//'))
        .toList();

    expect(
      code,
      isEmpty,
      reason: 'Something now runs between creating the loop and announcing it: '
          '${code.join(' ')}\nIf that is deliberate, keep the announcement '
          'first: anything that can throw in between leaves the screen holding '
          'a null loop again.',
    );
  });

  test('the keypad reaches the loop rather than a copy of the state', () {
    final screen = File('lib/ui/screens/call.dart').readAsStringSync();

    expect(
      screen,
      contains('loop?.sendDigit'),
      reason: 'The keypad no longer sends through the loop. Whatever replaces '
          'it still has to reach something that exists at the time a key is '
          'pressed, which was the whole fault here.',
    );
  });
}
