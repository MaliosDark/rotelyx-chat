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

  /// What a wake that found nothing is filed under.
  ///
  /// It exists so those can be told apart from real ones and taken away again.
  /// Handing back empty content does not drop a notification, which is what
  /// this code believed and `docs/PUSH.md` still said: iOS posts it with no
  /// title and no body, and that blank Rotelyx banner every few minutes is
  /// what people were getting. Dropping one outright needs
  /// `com.apple.developer.usernotifications.filtering`, which Apple grants by
  /// hand and this application has not been given.
  ///
  /// So the blank is made as quiet as the system allows and does not
  /// accumulate. That is the floor until the entitlement arrives.
  static let quietThread = "rotelyx.wake.nothing"

  /// Clear the blanks left by earlier wakes.
  ///
  /// Delivered notifications are shared with the application, so this reaches
  /// them from the extension as readily as from the app itself.
  /// As close to silence as iOS allows, which is not silence.
  ///
  /// No sound, no wrist tap, no screen waking, no place in a summary, and
  /// filed under a thread of its own so the next wake can take it away.
  static func quiet() -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.sound = nil
    content.interruptionLevel = .passive
    content.relevanceScore = 0
    content.threadIdentifier = NotificationService.quietThread
    return content
  }

  static func sweepQuiet() {
    let centre = UNUserNotificationCenter.current()
    centre.getDeliveredNotifications { delivered in
      let blanks = delivered
        .filter { $0.request.content.threadIdentifier == NotificationService.quietThread }
        .map { $0.request.identifier }
      guard !blanks.isEmpty else { return }
      centre.removeDeliveredNotifications(withIdentifiers: blanks)
    }
  }

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    handler = contentHandler
    content = request.content.mutableCopy() as? UNMutableNotificationContent

    // Take away the last blank one before adding to the pile.
    //
    // A wake arrives every few minutes whether or not anything is waiting, so
    // without this a phone left alone overnight collects a few hundred empty
    // lines. Each run clears what the run before it left, which holds the
    // total at one.
    NotificationService.sweepQuiet()

    guard let content = content else {
      contentHandler(request.content)
      return
    }

    // A wake that is not from the sweep is a message that exists.
    //
    // `decoy` says which this is. The mailbox's clock wakes every registered
    // device whether or not anything arrived, and those may find nothing. A
    // wake handed on by the notifier came from a ticket, and a ticket only
    // opens for something that was actually deposited, so there is nothing to
    // ask and nothing that could come back empty.
    //
    // This is the whole of the blank notification problem. The flag used to be
    // a constant `true` on the server, so a real arrival arrived saying it
    // might be nothing; the extension asked the mailbox, and answered zero
    // whenever the application had already collected the message or the
    // network was not there. Zero meant empty content, and empty content is a
    // blank banner rather than silence.
    //
    // Told which it is, a real arrival never asks and so can never be blank,
    // even with no signal at all.
    let sweep = request.content.userInfo["decoy"] as? Bool
      ?? (request.content.userInfo["decoy"] as? String).map { $0 == "true" }
      ?? true

    guard sweep else {
      LastWake.write(decoy: false, waiting: nil, ending: .ticket)
      content.title = "Rotelyx"
      content.body = "New message"
      contentHandler(content)
      return
    }

    // From here down it is the sweep, which genuinely may find nothing.
    Waiting.check { waiting in
      // Not knowing is not the same as knowing there is nothing.
      //
      // A wake arrives when the application is closed, which is when the
      // network is least likely to answer inside the seconds this gets. The
      // answer used to be zero either way, and zero meant a blank banner. Now
      // a question that could not be asked shows the message the payload came
      // with, which is the honest thing: something woke this phone and nobody
      // established that it was nothing.
      // Could not ask, so this says nothing rather than guessing.
      //
      // Only a scheduled wake ever reaches here: a ticket says a message
      // exists and returns above without asking anybody. So the choice at this
      // point is between a blank and a sentence that might be false, and a
      // notification that claims a message nobody sent is worse than one that
      // says nothing. The blank is the sweep's cost and the sweep is what
      // should not be running.
      guard let waiting = waiting else {
        LastWake.write(decoy: true, waiting: nil, ending: .unknown)
        contentHandler(NotificationService.quiet())
        return
      }

      guard waiting > 0 else {
        // Nothing there.
        //
        // Silence is what this wants and is not what iOS gives. Handing back
        // empty content does not drop the notification, it posts one with no
        // title and no text, which is the blank Rotelyx banner people were
        // getting. Dropping it needs
        // `com.apple.developer.usernotifications.filtering`, which Apple grants
        // by hand and this application does not have.
        //
        // So it is made as close to silence as the system allows: no sound, no
        // wrist tap, no screen waking, no place in a summary. It is still a
        // line in Notification Centre, and until the entitlement arrives that
        // is the floor.
        //
        // Worth being plain about why these wakes happen at all: the server
        // sends the same one whether a message is waiting or not, on purpose,
        // so that somebody watching the traffic cannot tell when you are being
        // written to. The blank ones are that promise being kept.
        LastWake.write(decoy: true, waiting: 0, ending: .nothing)
        contentHandler(NotificationService.quiet())
        return
      }

      // Something arrived. It is not read here: the message stays sealed in
      // the mailbox until the application collects it, so this says that and
      // deliberately does not invent a sender.
      LastWake.write(decoy: true, waiting: waiting, ending: .waiting)
      content.title = "Rotelyx"
      content.body = waiting == 1 ? "New message" : "\(waiting) new messages"
      contentHandler(content)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    // Out of time. Show what arrived rather than nothing at all.
    //
    // What arrived is the server's own wake, and since it started carrying a
    // body that is a complete notification. A server older than that sends a
    // title and nothing under it, and iOS draws that as a blank. Filling it in
    // here was tried and taken out again: the only wake that can still be
    // waiting on an answer at this point is a scheduled one, which may have
    // found nothing, and a sentence announcing a message that does not exist
    // is worse than the blank it replaces.
    if let handler = handler, let content = content {
      LastWake.write(decoy: true, waiting: nil, ending: .expired)
      handler(content)
    }
  }
}
