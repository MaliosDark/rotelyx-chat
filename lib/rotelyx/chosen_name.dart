/// A name to offer when meeting somebody, invented rather than asked for.
///
/// # Why this exists
///
/// Pairing asks for "your name" and it is the first thing anybody has to do.
/// It is also the least important: the field says so itself, that it is only a
/// label and anybody can pick any of them, and that it is not how you know who
/// you are talking to. That is the safety number's job.
///
/// So a field that stops somebody until they invent something is asking them
/// to work for a value that does not matter, at the moment they are trying to
/// do the thing that does. It is filled in for them instead, and they can
/// change it.
///
/// # Where the words come from
///
/// The recovery phrase list in `passphrase.dart`, which is already in the
/// application, already reviewed, and already chosen to be short, common and
/// hard to mishear. Reusing it means no second list to keep, and nothing about
/// the name is a secret: it is shown to whoever is being met, and the person
/// choosing it is free to type anything else.
library;

import 'dart:math';

import 'passphrase.dart' show phraseWords;

/// Not `Random.secure`.
///
/// A display name is not a secret and does not need to resist guessing. The
/// secure generator is reserved for things that do, which keeps the reading of
/// this file honest about which is which.
final _pick = Random();

/// Two words, capitalised, as one name.
///
/// Two rather than one because a single common word is a name several people
/// in a group would land on, and this has to be distinguishable at a glance in
/// a list of conversations. Two of a few hundred words is enough that a
/// collision is a curiosity rather than a problem, and short enough to fit
/// where a name goes.
String suggestName() {
  final a = phraseWords[_pick.nextInt(phraseWords.length)];
  final b = phraseWords[_pick.nextInt(phraseWords.length)];
  return '${_capitalised(a)} ${_capitalised(b)}';
}

String _capitalised(String word) =>
    word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);
