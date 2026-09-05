import UserNotifications

/// Turning a content-free wake into a readable notification, on the device.
///
/// # Why an extension exists at all
///
/// The push that Apple carries contains nothing. It has to: a payload with the
/// message in it would be a message handed to Apple, and the whole arrangement
/// exists so that Apple learns a device was woken and not what for.
///
/// So the notification that arrives says nothing useful, and iOS gives this
/// extension about thirty seconds to replace it with something that does. It
/// runs in its own process, wakes with the push, does the work, and hands back
/// a notification with the sender's name and their message in it.
///
/// # What it is allowed to do, and the deadline
///
/// Thirty seconds, and if it overruns, iOS shows the untouched notification
/// instead. `serviceExtensionTimeWillExpire` is the last chance to deliver
/// something, and delivering the unhelpful original is better than delivering
/// nothing: a wake with no notification is a battery cost the user paid for no
/// reason and cannot see.
///
/// # It asks the mailbox whether anything arrived
///
/// Every wake this system sends carries `decoy`, because the server sends the
/// same wake whether or not anything arrived: that is what keeps the rhythm
/// Apple observes from saying who was messaged. The flag means "you may find
/// nothing", and it used to be read as "show nothing", so **every** wake
/// produced a silent notification and a person with a message waiting was told
/// nothing until they opened the application themselves.
///
/// So this asks. The application leaves the tags it listens on in the shared
/// container; this connects to the mailbox, subscribes to them, and reads the
/// count of envelopes waiting out of the `ready` reply. Nothing is shown when
/// that count is zero, which is what a decoy is, and a notification is shown
/// when it is not.
///
/// # What it still does not do
///
/// Decrypt. The message stays in the mailbox and is read by the application,
/// so this says that something arrived and not what or from whom. Doing better
/// needs the conversation store open in this process, which needs the vault
/// key out of the shared keychain, and that is the next step rather than this
/// one.
///
/// A notification that named the wrong person would be worse than one that
/// names nobody.
///
/// See `docs/PUSH.md` for the payload contract.
class NotificationService: UNNotificationServiceExtension {

  private var handler: ((UNNotificationContent) -> Void)?
  private var content: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    handler = contentHandler
    content = request.content.mutableCopy() as? UNMutableNotificationContent

    guard let content = content else {
      contentHandler(request.content)
      return
    }

    // Ask the mailbox whether anything is actually waiting.
    //
    // `decoy` on the payload means "you may find nothing", not "there is
    // nothing": the server cannot tell, and sends the same wake either way on
    // purpose. Only the mailbox knows, and only this device can ask it.
    Waiting.check { waiting in
      guard waiting > 0 else {
        // Nothing there. Silence rather than a notification about nothing,
        // which is what every wake used to produce.
        contentHandler(UNMutableNotificationContent())
        return
      }

      // Something arrived. It is not read here: the message stays sealed in
      // the mailbox until the application collects it, so this says that and
      // deliberately does not invent a sender.
      content.title = "Rotelyx"
      content.body = waiting == 1 ? "New message" : "\(waiting) new messages"
      contentHandler(content)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    // Out of time. Show what arrived rather than nothing at all.
    if let handler = handler, let content = content {
      handler(content)
    }
  }
}
