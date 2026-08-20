/// Writing a conversation out, in plain text.
///
/// # The warning belongs with the feature, not beside it
///
/// Everything else here is arranged so that a conversation exists encrypted or
/// not at all. Exporting undoes that on purpose: what comes out is readable by
/// anything that can read a file, it is no longer covered by the passphrase,
/// and wherever it lands is somewhere this application has no say over.
///
/// That is a legitimate thing to want, and it is the single fastest way to lose
/// the property the rest of the application is for. So the text says so at the
/// top of the file itself, where somebody reading the export sees it, rather
/// than only in a dialog they clicked through a week earlier.
///
/// # What is deliberately not included
///
/// Message identifiers, mailbox tags, the safety number and anything about the
/// session. An export is for a person to read, and those are handles that would
/// only be useful for correlating this conversation with something else.
library;

import 'ephemeral.dart';
import 'quoted.dart';
import 'rotelyx_store.dart';
import 'signal.dart';

/// One conversation as text.
String exportConversation(StoredConversation c) {
  final out = StringBuffer();

  out.writeln(c.displayTitle);
  out.writeln('Exported from Rotelyx on ${_day(DateTime.now())}');
  out.writeln();
  out.writeln('This file is not encrypted. Anything that can read it can read '
      'the conversation, and your passphrase does not cover it.');
  out.writeln('-' * 72);
  out.writeln();

  for (final m in c.messages) {
    // Control messages are not something a person wrote and have no business
    // in a transcript.
    if (Signal.isControl(m.text)) continue;

    final who = m.mine ? 'You' : (m.author.isEmpty ? c.displayTitle : m.author);
    final body = Quoted.plain(Ephemeral.plain(m.text));
    if (body.trim().isEmpty) continue;

    out.writeln('[${_time(m.at)}] $who');

    // A reply carries what it answered, so the transcript reads the way the
    // conversation did rather than as a list of disconnected lines.
    final quoted = Quoted.decode(Ephemeral.plain(m.text));
    if (quoted != null) {
      out.writeln('  > ${quoted.author}: ${quoted.excerpt}');
    }

    for (final line in body.split('\n')) {
      out.writeln('  $line');
    }

    if (m.reactions.isNotEmpty) {
      final marks = m.reactions.entries
          .map((e) => '${e.key} ${e.value.join(', ')}')
          .join('   ');
      out.writeln('  ($marks)');
    }

    out.writeln();
  }

  final kept = c.messages
      .where((m) => !Signal.isControl(m.text))
      .length;
  out.writeln('-' * 72);
  out.writeln('$kept messages.');

  // Said again at the bottom, because a long transcript is scrolled past and
  // the person who reaches the end is the one about to send it somewhere.
  out.writeln('Not encrypted. Keep it somewhere you would keep the '
      'conversation itself.');

  return out.toString();
}

String _day(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)}';

String _time(DateTime d) =>
    '${_day(d)} ${_two(d.hour)}:${_two(d.minute)}';

String _two(int n) => n.toString().padLeft(2, '0');
