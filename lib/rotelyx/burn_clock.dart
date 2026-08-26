/// Who starts a self destructing message's clock, and when.
///
/// # Why this is its own file
///
/// The rule has two halves that run on two different devices, in two different
/// layers: the conversation screen starts the clock on what it was sent, and
/// the service starts it on what it sent once the acknowledgement comes back.
/// Written twice, the two halves drift, and the way they drift is that a
/// message burns on one device and not on the other. That is the exact failure
/// the design exists to prevent, so the decision is made in one place and both
/// callers ask it rather than reimplementing it.
///
/// It is also the only shape of this logic that can be tested without a
/// mailbox, a session and two paired devices.
///
/// # The rule
///
/// A timer means "gone this long after you have read it". One reading, one
/// starting point, two clocks that begin at it:
///
///   * The recipient starts theirs when the conversation is opened, and sends
///     back the identifier of everything it started.
///   * The sender starts theirs when that identifier arrives, and not before.
///     Until then their copy has no deadline at all, because a message nobody
///     opened has not been read, and destroying it would tell the sender it
///     was seen.
///
/// The clocks are not synchronised and are not meant to be. They start from
/// the same event and run on two unrelated system clocks, so the sender's is
/// behind by however long the acknowledgement took to travel. Making them
/// agree would need a shared clock, which is the thing `ephemeral.dart` refuses
/// to depend on. Being a second or two late destroying your own copy is not a
/// property anybody needs; starting from the right event is.
library;

import 'ephemeral.dart';
import 'rotelyx_store.dart';

/// What a reading, on either side, changed.
class BurnStart {
  const BurnStart({
    required this.messages,
    required this.acknowledge,
    required this.changed,
  });

  /// The conversation's messages, with deadlines set on the ones that gained
  /// them. A fresh list: [StoredMessage] is immutable, and rewriting entries
  /// in place would leave a caller that kept a reference holding the old ones.
  final List<StoredMessage> messages;

  /// Identifiers to tell the other side about. Empty on the sending side,
  /// which has nobody to tell.
  final List<String> acknowledge;

  /// Whether anything moved. Callers save on this rather than saving always,
  /// so opening a conversation with nothing expiring in it does not rewrite
  /// the whole encrypted log every time.
  final bool changed;
}

/// The recipient has opened the conversation.
///
/// Starts a clock on everything they sent that has a timer and does not have a
/// deadline yet, and collects what to acknowledge. Our own messages are left
/// alone: theirs is the reading that counts, and we have not had it yet.
BurnStart onRead(
  List<StoredMessage> messages, {
  DateTime? now,

  /// Start the clock on our own messages as well.
  ///
  /// False everywhere except a conversation with yourself, where it has to be
  /// true and the ordinary rule gives the wrong answer. Normally a message of
  /// ours starts expiring when *they* read it, which is why `mine` is skipped
  /// below. In a note to self there is no they: both members are this device,
  /// so the person opening it is the recipient and opening it is the reading.
  ///
  /// Without this a note you set to burn never burns. It sits with a dash where
  /// the countdown should be, for as long as the conversation exists, which
  /// looks exactly like the feature being broken.
  bool ownMessagesToo = false,
}) {
  final at = now ?? DateTime.now();
  final out = List<StoredMessage>.of(messages);
  final acknowledge = <String>[];
  var changed = false;

  for (var i = 0; i < out.length; i++) {
    final m = out[i];
    if ((m.mine && !ownMessagesToo) || m.burnAt != null) continue;

    final ephemeral = Ephemeral.decode(m.text);
    if (ephemeral == null) continue;

    out[i] = m.copyWith(burnAt: at.add(Duration(seconds: ephemeral.seconds)));
    // Empty for a message from a build that predates identifiers. It still
    // burns here; there is simply nothing to name it by on the other side.
    if (ephemeral.id.isNotEmpty) acknowledge.add(ephemeral.id);
    changed = true;
  }

  return BurnStart(messages: out, acknowledge: acknowledge, changed: changed);
}

/// They have read the messages named by [ids], so ours may start expiring.
///
/// Only our own, and only the ones named. An acknowledgement is not a high
/// water mark: it says nothing about anything it does not list, which is what
/// keeps it from doubling as a read receipt for the rest of the conversation.
BurnStart onAcknowledged(List<StoredMessage> messages, Set<String> ids,
    {DateTime? now}) {
  final at = now ?? DateTime.now();
  final out = List<StoredMessage>.of(messages);
  var changed = false;

  if (ids.isEmpty) {
    return BurnStart(messages: out, acknowledge: const [], changed: false);
  }

  for (var i = 0; i < out.length; i++) {
    final m = out[i];
    if (!m.mine || m.burnAt != null) continue;

    final ephemeral = Ephemeral.decode(m.text);
    if (ephemeral == null || !ids.contains(ephemeral.id)) continue;

    out[i] = m.copyWith(
      // Read is read. The tick and the flame are the same fact here, so
      // marking it saves the other side from having to send both.
      seen: true,
      burnAt: at.add(Duration(seconds: ephemeral.seconds)),
    );
    changed = true;
  }

  return BurnStart(messages: out, acknowledge: const [], changed: changed);
}
