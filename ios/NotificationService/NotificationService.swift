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
/// # What is not built yet
///
/// The decryption. It needs the Rust library and the conversation store to be
/// reachable from this process, which means an App Group container shared with
/// the application and the same `librotelyx_mobile` linked into this target.
/// Until that is done this shows the sender's label if the payload carried one,
/// and "New message" otherwise, which is exactly what a lock screen with
/// content switched off shows anyway.
///
/// See `docs/PUSH.md` for the payload contract and the remaining steps.
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

    // A decoy wake. The mailbox sends these on a schedule whether or not
    // anything arrived, so that the rhythm Apple observes is the same for every
    // user and carries nothing about who was messaged. Nothing is shown.
    if content.userInfo["decoy"] as? Bool == true {
      contentHandler(UNMutableNotificationContent())
      return
    }

    // Everything below is a placeholder until the store is reachable from this
    // process. It deliberately does not invent a sender: a notification that
    // names the wrong person is worse than one that names nobody.
    content.title = "Rotelyx"
    content.body = "New message"

    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    // Out of time. Show what arrived rather than nothing at all.
    if let handler = handler, let content = content {
      handler(content)
    }
  }
}
