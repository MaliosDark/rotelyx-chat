/// Telling somebody a message arrived, without telling anybody else.
///
/// # The whole argument for this file
///
/// The ordinary way to notify a phone is Firebase on Android and APNs on iOS.
/// Neither reads the message: the payload can be empty or ciphertext. What they
/// get instead is the part that matters here.
///
/// |  | What Google or Apple learns |
/// |---|---|
/// | The text | Nothing |
/// | That this device received something | Yes |
/// | At what time, to the second | Yes |
/// | How often, and the weekly shape of it | Yes |
/// | The device's address when it arrived | Yes |
/// | A stable identifier for the install | Yes, the push token |
///
/// That is a traffic oracle. Whoever holds it knows when you talk, how much,
/// and from where, without reading a word. It is the same metadata the blind
/// mailbox exists to withhold, handed to a third party at the last step.
///
/// So this application posts its own notifications. It is connected already,
/// because it holds the mailbox socket itself, and a message is decrypted on
/// this device before anything is shown. Nothing leaves. See
/// `docs/NOTIFICATIONS.md` for the platform-by-platform reasoning, including
/// what iOS makes impossible and what is proposed instead.
library;

import 'dart:typed_data';

/// One arriving message, as the system will show it.
class Notice {
  const Notice({
    required this.conversationId,
    required this.sender,
    required this.body,
    this.picture,
    this.showContent = true,
    this.silent = false,
  });

  /// Which conversation. A second message from the same person replaces the
  /// first rather than stacking, because that is what a conversation is.
  final String conversationId;

  /// Their name as this device knows it: the nickname if one was set, the
  /// label they chose otherwise. Never a phone number, because there is none.
  final String sender;

  /// What they said, already decrypted.
  final String body;

  /// Their picture, if they have sent one. Shown beside the message.
  final Uint8List? picture;

  /// Whether [body] may be read on a locked screen.
  ///
  /// False shows the sender and "New message" instead. The choice is the
  /// application's to offer rather than the system's to make, because the
  /// system's answer is "Contents hidden", which withholds the useful half
  /// and the safe half together.
  final bool showContent;

  /// No sound and no vibration. A muted conversation still appears.
  final bool silent;
}

/// What a platform has to provide.
abstract class Notifier {
  /// Whether anything posted here would actually be shown.
  ///
  /// From Android 13 the default is refused, so this is not a formality: an
  /// application that assumes otherwise notifies nobody on every device sold
  /// since 2022.
  Future<bool> permitted();

  /// Ask, if the platform has something to ask.
  Future<bool> request();

  /// Show one.
  Future<void> show(Notice notice);

  /// Take down whatever is showing for a conversation, because it has been
  /// read on this device.
  Future<void> clear(String conversationId);

  /// Whether this platform can stay connected while the application is not in
  /// front, and therefore whether [connect] means anything.
  bool get canStayConnected;

  /// Keep this application's own connection alive in the background.
  ///
  /// On Android this starts a foreground service, which the system requires to
  /// exempt a process from having its network suspended. Without it the socket
  /// is frozen the moment the screen goes off, and a message deposited in the
  /// mailbox is not collected until somebody opens the application: measured
  /// on a device, not assumed. It costs a permanent notification and battery,
  /// which is why it is a switch and not a default.
  Future<bool> connect();

  /// Stop staying connected. Messages then arrive when the application is
  /// opened, which is the honest behaviour of an application that is not
  /// running.
  Future<void> disconnect();
}
