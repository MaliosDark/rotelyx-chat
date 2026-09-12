/// Deciding when to interrupt somebody.
///
/// # Why this is not in the service and not in a screen
///
/// The service knows a message arrived. A screen knows whether anybody is
/// looking at it. Neither knows both, and putting the decision in either one
/// gets it wrong in a way that is obvious the moment it ships: a service that
/// notifies always makes the phone buzz for the message being typed a reply
/// to, and a screen that notifies stops notifying the moment it is closed,
/// which is the only time it mattered.
///
/// So the decision lives here, with the three facts it needs: what arrived,
/// which conversation is on screen, and whether the application is in front.
///
/// # What is never sent anywhere
///
/// Everything. There is no push service in this path. The application holds the
/// mailbox socket itself, so a message is decrypted on this device before this
/// file is reached, and notifying is a local act. See `docs/PUSH.md` for what
/// would change if a device had to be woken while nothing was running, and why
/// that is a different problem with a different answer on each platform.
library;

import 'dart:async';

import '../platform/notify.dart';
import '../platform/watch.dart';
import '../platform/widgets.dart';
import 'attachment.dart';
import 'ephemeral.dart';
import 'quoted.dart';
import 'rotelyx_service.dart';
import 'rotelyx_store.dart';
import 'signal.dart';

/// Posts a notification when one is warranted, and not otherwise.
class Alerts {
  Alerts({Notifier? notifier}) : _notifier = notifier ?? const PlatformNotifier();

  final Notifier _notifier;
  final Watch _watch = PlatformWatch();
  StreamSubscription<RotelyxMessage>? _messages;

  /// The conversation on screen, or null when none is.
  ///
  /// Set by the conversation screen as it opens and cleared as it closes.
  String? openConversation;

  /// Whether the application is in front.
  ///
  /// The window may be visible with a conversation open and the phone still
  /// locked, or the application may be in the background with the last screen
  /// remembered. Both are cases where the conversation is "open" and a
  /// notification is still the right thing.
  bool inForeground = true;

  /// Whether a locked screen may show what was said.
  ///
  /// Default true, because a notification that says only "New message" makes
  /// somebody unlock their phone to find out whether it was worth unlocking
  /// their phone, and that is the setting most people turn off first.
  ///
  /// It is a real exposure and the switch is in settings for exactly that
  /// reason: anybody who can see the screen can read it, and that includes a
  /// shoulder in a queue and a camera in a room.
  bool showContentOnLockScreen = true;

  /// Begin watching. Safe to call twice.
  void start() {
    _messages ??= rotelyx.messages.listen(_arrived);

    // The watch asks this application for what it shows, so somebody has to be
    // listening before a wrist is raised. It holds no key and reaches no
    // server: see `lib/platform/watch_native.dart`.
    _watch.listen();

    // Replying from the notification itself, which is the thing a person
    // reaches for before opening anything. It goes through `rotelyx.send` like
    // any other message, and refuses the same way a screen would: a
    // conversation that is not the live one is resumed first, and one that
    // cannot be resumed is not written to.
    PlatformNotifier.onReply = _reply;
    _notifier.listenForReplies();
    showContentOnLockScreen = store.showPreviews;
    if (store.stayConnected) {
      _notifier.connect();
      rotelyx.askToBeWoken();
    }
  }

  Future<void> stop() async {
    await _messages?.cancel();
    _messages = null;
  }

  /// Ask for permission, once there is a reason to.
  ///
  /// Called after the first conversation exists rather than at first launch. A
  /// permission prompt on a screen that has not yet explained what the
  /// application is gets refused, and on Android 13 and later a refusal is
  /// final until somebody goes into system settings to undo it.
  Future<bool> request() => _notifier.request();

  Future<bool> permitted() => _notifier.permitted();

  /// Whether this platform can receive while the application is not in front,
  /// by either of the two mechanisms there are.
  ///
  /// A mailbox that has said it cannot wake anybody is left out, so the switch
  /// is absent rather than present and apologetic. Offering a setting that
  /// cannot do what it says is worse than not offering it.
  bool get canStayConnected =>
      _notifier.canStayConnected ||
      (rotelyx.canBeWoken && rotelyx.mailboxCanWake);

  /// Receive while the application is closed, or stop.
  ///
  /// One switch, two mechanisms, because the user is choosing an outcome and
  /// not an implementation:
  ///
  ///   * Android holds its own connection through a foreground service. No
  ///     third party is involved at all.
  ///   * iOS cannot hold a connection, so it registers with the mailbox to be
  ///     woken on a schedule. Apple carries the wake and learns that a device
  ///     received one, which Settings says rather than hides.
  ///
  /// Remembered on this device and re-applied at startup, because a service
  /// does not survive a reboot and a switch that silently turns itself off is
  /// worse than one that was never offered.
  Future<bool> stayConnected(bool want) async {
    store.stayConnected = want;

    if (!want) {
      await _notifier.disconnect();
      await rotelyx.stopBeingWoken();
      return false;
    }

    final held = await _notifier.connect();
    final woken = await rotelyx.askToBeWoken();
    return held || woken;
  }

  /// Send what somebody typed into a notification.
  ///
  /// The same refusal the conversation screen makes, for the same reason:
  /// acting on a session that belongs to another conversation sends the words
  /// to whoever that is.
  Future<void> _reply(String conversationId, String text) async {
    if (rotelyx.state != RotelyxState.joined ||
        rotelyx.conversationId != conversationId) {
      if (!await rotelyx.resume(conversationId)) return;
    }
    rotelyx.send(text);
    await read(conversationId);
  }

  /// A conversation has been read here, so whatever was showing for it goes.
  Future<void> read(String conversationId) {
    // The count has moved. A badge that only ever goes up is a badge people
    // learn to ignore.
    refreshWidgets();
    return _notifier.clear(conversationId);
  }

  Future<void> _arrived(RotelyxMessage message) async {
    // Ours. Sending a message from this device is not news to it.
    if (message.mine) return;

    // A receipt, a reaction or a picture. It travels as a message and is not
    // one, and waking somebody for a read receipt is how an application
    // teaches people to turn its notifications off.
    if (Signal.isControl(message.text)) return;

    final id = rotelyx.conversationId;
    if (id == null) return;

    final conversation = store.load(id);
    if (conversation == null) return;

    // The wrist, before the decision below. A watch is told even when this
    // conversation is open on the phone, because "open on the phone" is
    // precisely the case where the phone is in a hand and the watch is not the
    // thing being looked at, and being told is what keeps its list current.
    //
    // Muted travels with it. This used to be a bare call, so a conversation
    // somebody had deliberately silenced went on tapping their arm: the phone
    // was quiet about it and the watch was not, which is the half that is
    // actually attached to the person.
    _watch.arrived(silent: conversation.muted);

    // The home and lock screens, which cannot ask. What each is allowed to
    // carry is decided in `refreshWidgets`, and what it refuses is never
    // written rather than written and hidden.
    refreshWidgets();

    // Being looked at. The message is already on screen, and the phone
    // buzzing about it is noise.
    if (inForeground && openConversation == id) return;

    await _notifier.show(Notice(
      conversationId: id,
      sender: conversation.displayTitle,
      body: preview(message.text),
      picture: conversation.picture,
      showContent: showContentOnLockScreen,
      // Muted still appears in the shade, silently. Removing it entirely would
      // make a muted conversation one nobody discovers has moved.
      silent: conversation.muted,
    ));
  }

  /// What a notification should say a message was.
  ///
  /// The markers come off in the order they were put on, so a reply that
  /// expires reads as what was written rather than as its wrapping. An
  /// attachment has no text to show and is named by its kind instead.
  ///
  /// # The flame
  ///
  /// A message that destroys itself is one somebody has a limited time to read,
  /// and a notification that looks like every other notification is one that
  /// gets opened tomorrow. So it says so.
  ///
  /// It goes inside the text rather than beside the sender, and that placement
  /// is the whole safeguard: the text is what a locked screen withholds when
  /// previews are off. Put next to the name it would survive that setting, and
  /// a flame on a lock screen tells whoever is glancing at it which message is
  /// the one worth reading over your shoulder, which is the fact that setting
  /// exists to keep.
  static String preview(String text) {
    final burns = Ephemeral.isEphemeral(text);
    final body = Quoted.plain(Ephemeral.plain(text));
    final said = attachmentSummary(body) ??
        (body.trim().isEmpty ? 'Attachment' : body);
    return burns ? '🔥 $said' : said;
  }
}

/// The one this application uses.
final Alerts alerts = Alerts();
