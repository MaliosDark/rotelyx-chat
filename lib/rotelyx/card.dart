/// A message with buttons under it.
///
/// # What this is for
///
/// A bot that asks a question in plain text makes every person who answers it
/// type a command exactly right, and a bot that explains its commands is a bot
/// nobody reads. Everywhere else this is solved with buttons; here it was the
/// first thing he asked about after seeing the bots ("they generate messages
/// like the ones on Telegram, with buttons?"), and the answer was no.
///
/// So a bot can send a card: a title, a line or two, and up to six buttons. It
/// is an ordinary message on the wire, with a marker in front like an
/// attachment or a reply, and a build that has never seen one shows it as the
/// title and text with the buttons listed underneath rather than losing it.
///
/// # What a tap does, and what it does not
///
/// A tap sends a control message back to the conversation carrying the
/// button's command, which the bot reads and nobody sees. That is the same
/// envelope every other message travels in: the mailbox learns nothing it did
/// not already learn from somebody typing a reply, and no callback goes
/// anywhere but into the conversation itself.
///
/// The commands are the bot's own words, not an interface for the button to
/// call anything on the phone. Nothing here runs a command on this device.
library;

/// Marks a message body as a card.
const String _marker = '\x01rx-card\x01';
const String _field = '\x01';
const String _pair = '\x1f';

/// The most buttons one card may carry.
///
/// Six, because a card with a screen of buttons is a menu, and a menu is the
/// thing buttons exist to avoid. It also bounds what arrives from a stranger.
const int maxButtons = 6;

class CardButton {
  const CardButton({required this.label, required this.command});

  /// What it says.
  final String label;

  /// What the bot is told when it is pressed. Never shown.
  final String command;
}

class BotCard {
  const BotCard({
    required this.title,
    required this.text,
    required this.buttons,
  });

  final String title;
  final String text;
  final List<CardButton> buttons;

  /// Pack for sending. Every part is percent-encoded, so a title carrying the
  /// separator cannot invent a button.
  String encode() {
    final out = StringBuffer(_marker)
      ..write(Uri.encodeComponent(title))
      ..write(_field)
      ..write(Uri.encodeComponent(text));
    for (final button in buttons.take(maxButtons)) {
      out
        ..write(_field)
        ..write(Uri.encodeComponent(button.label))
        ..write(_pair)
        ..write(Uri.encodeComponent(button.command));
    }
    return out.toString();
  }

  /// Null when this is not a card, which is the common case.
  static BotCard? decode(String body) {
    if (!body.startsWith(_marker)) return null;
    final parts = body.substring(_marker.length).split(_field);
    if (parts.length < 2) return null;

    try {
      final buttons = <CardButton>[];
      for (final part in parts.sublist(2)) {
        final split = part.indexOf(_pair);
        if (split <= 0) continue;
        final label = Uri.decodeComponent(part.substring(0, split));
        final command = Uri.decodeComponent(part.substring(split + 1));
        if (label.isEmpty || command.isEmpty) continue;
        buttons.add(CardButton(label: label, command: command));
        if (buttons.length == maxButtons) break;
      }

      return BotCard(
        title: Uri.decodeComponent(parts[0]),
        text: Uri.decodeComponent(parts[1]),
        buttons: buttons,
      );
    } on Object {
      // A card that does not decode is not shown as one. The message is still
      // read as text by whoever drew it, which is the honest failure.
      return null;
    }
  }

  /// What a list or a notification says a card was.
  static String? summary(String body) {
    final card = decode(body);
    if (card == null) return null;
    if (card.title.isNotEmpty && card.text.isNotEmpty) {
      return '${card.title}: ${card.text}';
    }
    return card.title.isNotEmpty ? card.title : card.text;
  }
}
