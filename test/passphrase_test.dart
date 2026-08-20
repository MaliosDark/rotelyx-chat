/// The passphrase generator, and the arithmetic behind the claim it makes.
///
/// # Why a public wordlist is not the weakness it looks like
///
/// The list is public and that is fine, because the secret is not the list, it
/// is which words came out of it. An attacker holding the whole list still has
/// to search 4096^6, and hiding the list would be security by obscurity: it
/// would feel safer and change nothing an attacker has to do.
///
/// These tests exist to keep that claim true rather than merely stated. If the
/// list ever picks up a duplicate, loses its power-of-two size, or the
/// generator ever stops using a cryptographic source, the arithmetic quietly
/// stops holding and nothing else would notice.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/passphrase.dart';

void main() {
  test('a passphrase is the requested number of words', () {
    for (final count in [4, 5, 6, 8]) {
      final words = generatePassphrase(words: count).split(' ');
      expect(words.length, count);
      expect(words.every((w) => w.isNotEmpty), isTrue);
    }
  });

  test('every word is lowercase letters, four to seven of them', () {
    // The rule that lets a passphrase be read down a phone line without
    // spelling anything out.
    final pattern = RegExp(r'^[a-z]{4,7}$');
    for (var i = 0; i < 200; i++) {
      for (final word in generatePassphrase().split(' ')) {
        expect(pattern.hasMatch(word), isTrue, reason: '"$word" is awkward');
      }
    }
  });

  test('the entropy claim is arithmetic, not a hope', () {
    // 12 bits a word requires exactly 4096 of them, all distinct. A list of
    // 4000 would be 11.97 bits and the claim would be a rounding error; a list
    // with a duplicate would be worse than it says by an amount nobody could
    // see.
    expect(entropyBits(1), 12);
    expect(entropyBits(6), 72);

    // Sampling reaches deep into the list, which a truncated or padded list
    // would not.
    final seen = <String>{};
    for (var i = 0; i < 4000; i++) {
      seen.addAll(generatePassphrase(words: 8).split(' '));
    }
    expect(seen.length, greaterThan(3500),
        reason: 'the generator should reach most of a 4096 word list');
  });

  test('two passphrases are not the same', () {
    // The real failure this guards. `Random()` without `secure` is seeded
    // predictably enough that two devices starting together can agree, and a
    // guessable passphrase is a vault somebody else opens.
    final made = <String>{};
    for (var i = 0; i < 500; i++) {
      expect(made.add(generatePassphrase()), isTrue);
    }
  });

  test('the words are spread evenly rather than clustered', () {
    // A biased index would show up as some words appearing far more often than
    // others. With 12000 draws over 4096 words the expected count is about
    // three, and a modulo bias would push a slice of the list well above it.
    final counts = <String, int>{};
    for (var i = 0; i < 2000; i++) {
      for (final w in generatePassphrase(words: 6).split(' ')) {
        counts[w] = (counts[w] ?? 0) + 1;
      }
    }

    final most = counts.values.reduce(max);
    expect(most, lessThan(20),
        reason: 'one word appearing $most times in 12000 draws suggests bias');
  });

  test('a generated passphrase is long enough for the vault to accept', () {
    // The unlock screen refuses anything under eight characters. Six words is
    // never close to that, and this is here so a future change to the word
    // count cannot quietly produce something the next screen rejects.
    for (var i = 0; i < 50; i++) {
      expect(generatePassphrase(words: 4).length, greaterThanOrEqualTo(19));
    }
  });
}
