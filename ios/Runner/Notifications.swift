import Flutter
import UIKit
import UserNotifications

/// Notifications this application posts itself, while it is running.
///
/// # Why there are two ways a notification appears on iOS, and this is the good one
///
/// `ios/NotificationService/` is the other, and it runs when nothing else can:
/// the phone is locked, the application is not resident, and a push has woken a
/// separate process that has never seen the passphrase. It cannot open the
/// message, so it says that something arrived and no more.
///
/// This runs when the application is alive and has already decrypted the
/// message, which is the ordinary case for a phone in a hand. Everything the
/// notification needs is in memory: the sender, the text, the picture. The same
/// contract as `android/.../Notifications.kt`, deliberately, so that
/// `lib/rotelyx/alerts.dart` decides once and neither platform is a special
/// case above it.
///
/// It was missing entirely. `PlatformNotifier.show` was gated on
/// `Platform.isAndroid`, so an iPhone with the application open and the message
/// already on screen posted nothing at all, and the only notification an iPhone
/// ever showed was the extension's contentless one.
enum Notifications {

    /// The category that carries the reply box, and the action inside it.
    ///
    /// Registered once at launch rather than per notification: iOS keys a
    /// notification to a category by name, and a name it has never been told
    /// about arrives with no actions and no way to say why.
    static let category = "rotelyx.message"
    static let replyAction = "rotelyx.reply"

    /// Tell iOS what a message notification can do.
    ///
    /// Replying from the shade is what every other messenger does and what a
    /// person reaches for first. It is cheap here because the application is
    /// the one that posted the notification, so it is running and holds the
    /// session: the text goes straight into the conversation without a screen
    /// being opened.
    static func registerCategory() {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message")

        let category = UNNotificationCategory(
            identifier: Notifications.category,
            actions: [reply],
            intentIdentifiers: [],
            options: [])

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// The sound a message makes.
    ///
    /// `tool/sound/build.py` generates it and Android has played it since the
    /// beginning, through the notification channel. iOS was left on
    /// `UNNotificationSound.default`, so the same application announced itself
    /// with its own tone on one platform and with Apple's on the other.
    ///
    /// The file is a bundle resource rather than a Flutter asset. A Flutter
    /// asset lands under `flutter_assets/` with a key only Dart can resolve,
    /// and `UNNotificationSound` takes a name it looks for in the bundle root
    /// and in `Library/Sounds`, so it would never have found it there.
    ///
    /// It falls back to the system sound if the file is missing, which is the
    /// right failure: a notification with the wrong tone still tells somebody
    /// they have a message.
    static let tone: UNNotificationSound = {
        guard Bundle.main.url(forResource: "message", withExtension: "wav") != nil
        else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName("message.wav"))
    }()

    /// Whether the person allowed them, without asking again.
    static func permitted(_ result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { result(allowed) }
        }
    }

    /// Ask. Answering twice does not prompt twice: iOS returns the standing
    /// decision, and a refusal stands until it is changed in Settings.
    static func request(_ result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            DispatchQueue.main.async { result(granted) }
        }
    }

    /// Post one.
    ///
    /// # The lock screen decision, which is the person's
    ///
    /// `showContent` is the switch in Settings. iOS has no per-notification
    /// visibility the way Android does, so withholding is done by not putting
    /// the words there: with it off the notification carries the sender and
    /// "New message", and the text stays where only an unlocked application can
    /// reach it.
    ///
    /// The picture is attached only when content may be shown, for the same
    /// reason. An attachment has to be a file on disk, so it is written to the
    /// caches directory under a name derived from the conversation, replacing
    /// whatever was there for it before.
    static func show(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? Int
        else {
            result(nil)
            return
        }

        let title = args["title"] as? String ?? "Rotelyx"
        let body = args["body"] as? String ?? ""
        let showContent = args["showContent"] as? Bool ?? true
        let silent = args["silent"] as? Bool ?? false

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = showContent ? body : "New message"
        content.sound = silent ? nil : Notifications.tone

        // Grouped by conversation, so a thread's notifications collapse
        // together the way every other messenger's do rather than stacking one
        // per message.
        content.threadIdentifier = String(id)

        // What makes the reply box appear. The conversation travels with it,
        // because the shade hands back the action and the notification and
        // nothing else.
        content.categoryIdentifier = Notifications.category
        content.userInfo = ["conversation": args["conversationId"] as? String ?? ""]

        if showContent, let picture = (args["picture"] as? FlutterStandardTypedData)?.data,
           let attachment = attach(picture, id: id) {
            content.attachments = [attachment]
        }

        // The same identifier per conversation, so a later message replaces the
        // earlier notice instead of adding to a pile.
        let request = UNNotificationRequest(
            identifier: String(id), content: content, trigger: nil)

        // And take down the push's version of the same news.
        //
        // Two paths reach a person about one message. This one, which knows
        // who wrote and what they said, and the notification extension, woken
        // by a push, which knows only that something arrived. While the
        // application is still alive in the background both run, and the
        // result was two notifications for one message, the second of them
        // saying almost nothing.
        //
        // Every wake collapses onto one identifier at the push service, so
        // there is only ever one of those to take down, and this one is
        // strictly the better of the two.
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Notifications.wakeNotice])

        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.async { result(nil) }
        }
    }

    /// The identifier every push wake arrives under.
    ///
    /// It is the `apns-collapse-id` the mailbox and the notifier send, which
    /// iOS uses as the notification's identifier, so all of them replace each
    /// other and there is never more than one.
    static let wakeNotice = "rotelyx-wake"

    /// Take down whatever is showing for a conversation, because it has been
    /// read on this device.
    static func clear(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? Int
        else {
            result(nil)
            return
        }

        let key = String(id)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [key])
        center.removePendingNotificationRequests(withIdentifiers: [key])
        result(nil)
    }

    /// Write the picture where a notification attachment can reach it.
    ///
    /// Caches rather than the App Group container: this is a thumbnail iOS
    /// copies when the notification is posted, it is worthless afterwards, and
    /// the system is free to reclaim it. Nothing sealed is written here.
    private static func attach(_ data: Data, id: Int) -> UNNotificationAttachment? {
        guard let dir = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { return nil }

        let url = dir.appendingPathComponent("rotelyx-notice-\(id).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: "picture", url: url)
        } catch {
            // A notification without its picture is still the notification.
            return nil
        }
    }
}
