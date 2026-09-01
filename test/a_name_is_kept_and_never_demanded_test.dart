/// The name offered when meeting somebody is remembered, and never blank.
///
/// # The defect this exists for
///
/// `pair.dart` filled its name field from `store.load('me')?.title` and
/// nothing in the application ever wrote that. So the field was empty on every
/// visit: somebody who had already met one person typed their own name again
/// to meet a second, and again for a third, and nothing was wrong enough to
/// report. A setting that is read and never written looks exactly like a
/// setting that has not been set yet.
///
/// It is checked here because the two halves live in different files and each
/// is correct on its own. Only their pairing is the fault, and that is
/// precisely what nothing was looking at.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/chosen_name.dart';

void main() {
  test('a suggested name is two ordinary words and is not empty', () {
    for (var i = 0; i < 50; i++) {
      final name = suggestName();
      expect(name.trim(), isNotEmpty);
      expect(name.split(' ').length, 2, reason: '"$name" is not two words');
      expect(name[0], name[0].toUpperCase(),
          reason: '"$name" should read as a name, not as a word');
    }
  });

  test('two suggestions differ, so a list of them is legible', () {
    // Not a guarantee about any one pair, which would be a test of the random
    // generator. Fifty draws from a list of several hundred landing on one
    // value would mean the list or the draw is broken.
    final seen = <String>{for (var i = 0; i < 50; i++) suggestName()};
    expect(seen.length, greaterThan(20),
        reason: 'fifty suggestions produced only ${seen.length} distinct '
            'names, so either the word list or the draw has collapsed');
  });

  test('the name is written as well as read', () {
    final store = File('lib/rotelyx/rotelyx_store.dart').readAsStringSync();
    final pair = File('lib/ui/screens/pair.dart').readAsStringSync();

    expect(store, contains('String? get myName'),
        reason: 'the setting is gone. Whatever replaces it still has to be '
            'both readable and writable, which was the whole fault.');
    expect(store, contains('set myName'),
        reason: 'the setting can be read and not written, which is exactly '
            'the shape of the defect this test exists for: the field will be '
            'blank on every visit and nothing will report it.');

    expect(pair, contains('store.myName ?? suggestName()'),
        reason: 'the field no longer falls back to a suggestion, so somebody '
            'meeting their first person is stopped to invent a label that the '
            'screen itself says does not identify them.');
    expect(pair.contains('store.myName ='), isTrue,
        reason: 'nothing saves the name, so it is read from a setting that '
            'stays empty forever.');
  });

  test('nothing still reads the setting that was never written', () {
    // Comments stripped first: the fix is explained in one, and a check that
    // fails on its own explanation teaches people to delete the explanation.
    final pair = File('lib/ui/screens/pair.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    expect(pair, isNot(contains("store.load('me')")),
        reason: "load('me') is back. Nothing writes it: it was a conversation "
            'lookup standing in for a setting, and it returned null every '
            'time.');
  });
}
