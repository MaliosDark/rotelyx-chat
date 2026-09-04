import Flutter
import UIKit
import UserNotifications

/// Registering with Apple, and with nobody else.
///
/// # What this does and does not carry
///
/// It asks iOS to register for remote notifications and hands the resulting
/// token to Dart. That is all. There is no SDK here: no Firebase, no analytics,
/// no configuration file downloaded at launch. The token goes to the mailbox,
/// which is the user's own server, and the mailbox is what calls Apple.
///
/// Firebase would not have made this shorter. It cannot deliver to an iPhone by
/// itself; it relays to APNs, so a push sent through it is seen by Apple, who
/// was always going to see it, and by Google, who was not.
///
/// # Why the token is fetched rather than pushed
///
/// `registerForRemoteNotifications` returns at once and the token arrives later
/// in a delegate callback. A Dart side written around that callback has to
/// survive arriving before it is listening, which is a race that shows up on
/// slow devices and nowhere else. So the token is held here and handed over
/// when asked, and Dart sees one `await`.
@main
@objc class AppDelegate: FlutterAppDelegate {

  private static let channelName = "rotelyx/apple-push"

  /// The same channel name Android answers on, and deliberately so: the Dart
  /// side asks one question about permission and does not know which platform
  /// replies. Only two of Android's methods are answered here, because only two
  /// of them mean anything on iOS.
  ///
  /// `show` and `clear` are Android's, where the application holds its own
  /// connection and decides to notify. iOS cannot hold that connection: the
  /// notification is written by the extension in `ios/NotificationService/`
  /// when a push arrives, and nothing in Dart posts one.
  ///
  /// `connect` and `disconnect` are the foreground service, which iOS has no
  /// equivalent of. Its equivalent outcome, receiving while closed, is the
  /// wake registration in `rotelyx_service.dart`.
  private static let notifyChannelName = "rotelyx/notifications"

  /// The token, once Apple has given one.
  private var token: String?

  /// Callers waiting for it, because the first request usually arrives before
  /// registration has finished.
  private var waiting: [FlutterResult] = []

  private var audio: CallAudio?
  private var camera: QrCamera?
  private var files: FilePicker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: AppDelegate.channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "token":
          self?.requestToken(result)
        case "container":
          // Where the conversation log goes, so the notification extension can
          // see it. Nil when the App Group is not provisioned, and Dart falls
          // back to this application's own container rather than refusing to
          // start: history is worth more than the extension's view of it.
          result(SharedContainer.path)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let notify = FlutterMethodChannel(
        name: AppDelegate.notifyChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      notify.setMethodCallHandler { call, result in
        switch call.method {
        case "permitted":
          // What iOS currently allows, which is not what was asked for: a
          // person can grant at the prompt and revoke in Settings afterwards,
          // and a switch that remembers the prompt rather than reading the
          // system drifts out of step with it silently.
          UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
              || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { result(allowed) }
          }
        case "request":
          // Asking twice is not an error and does not prompt twice: iOS
          // answers the second call with the standing decision. A refusal is
          // final until the person changes it in Settings, which is what the
          // Dart side tells them.
          UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
          ) { granted, _ in
            DispatchQueue.main.async { result(granted) }
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    if let controller = window?.rootViewController as? FlutterViewController {
      // The three platform channels, in the same shapes Android answers on, so
      // nothing above them knows which platform it is talking to.
      let calls = CallAudio()
      audio = calls
      FlutterMethodChannel(name: CallAudio.channel,
                           binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler { call, result in calls.handle(call, result) }

      let scanner = QrCamera(registry: registrar(forPlugin: "QrCamera")?.textures())
      camera = scanner
      FlutterMethodChannel(name: QrCamera.channel,
                           binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler { call, result in scanner.handle(call, result) }

      let picker = FilePicker(host: controller)
      files = picker
      FlutterMethodChannel(name: FilePicker.channel,
                           binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler { call, result in picker.handle(call, result) }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Ask the user, then ask Apple.
  ///
  /// The permission prompt comes first because registering without it produces
  /// a token that can be woken but can show nothing, which is worse than no
  /// token: the device is woken, spends battery, and the user sees nothing and
  /// cannot tell why.
  private func requestToken(_ result: @escaping FlutterResult) {
    if let token = token {
      result(token)
      return
    }

    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { [weak self] granted, _ in
      guard let self = self else { return }

      guard granted else {
        // Refused. Not an error: the application receives when it is opened,
        // which is the same behaviour as Android with its background
        // connection switched off.
        DispatchQueue.main.async { result(nil) }
        return
      }

      DispatchQueue.main.async {
        self.waiting.append(result)
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    token = hex
    waiting.forEach { $0(hex) }
    waiting.removeAll()

    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // No network, no entitlement, or a simulator. Answered rather than left
    // hanging: a Dart future that never completes is a settings screen that
    // spins forever.
    waiting.forEach { $0(nil) }
    waiting.removeAll()

    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
  }
}
