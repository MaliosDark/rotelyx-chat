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
        content.sound = silent ? nil : .default

        // Grouped by conversation, so a thread's notifications collapse
        // together the way every other messenger's do rather than stacking one
        // per message.
        content.threadIdentifier = String(id)

        if showContent, let picture = (args["picture"] as? FlutterStandardTypedData)?.data,
           let attachment = attach(picture, id: id) {
            content.attachments = [attachment]
        }

        // The same identifier per conversation, so a later message replaces the
        // earlier notice instead of adding to a pile.
        let request = UNNotificationRequest(
            identifier: String(id), content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.async { result(nil) }
        }
    }

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
