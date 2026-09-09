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

  /// Held for the life of the application, because `WCSession` keeps a weak
  /// delegate and a bridge that goes out of scope is a watch that stops being
  /// answered.
  private var watch: WatchBridge?

  /// The channel that carries a link to Dart, and the one this launch began
  /// with while nothing is listening yet.
  ///
  /// A launch from cold reaches `open url:` before the engine exists, so the
  /// link is held rather than pushed into nothing: a widget that does nothing
  /// the first time it is tapped is a widget people tap once.
  private var links: FlutterMethodChannel?
  private var launchedBy: String?

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard url.scheme == "rotelyx" else {
      return super.application(app, open: url, options: options)
    }

    if let links = links {
      links.invokeMethod("link", arguments: url.absoluteString)
    } else {
      launchedBy = url.absoluteString
    }
    return true
  }

  /// A tapped invitation link, which arrives here and not through `open url:`.
  ///
  /// # Why there are two of these
  ///
  /// `open url:` is for a scheme this application registered, `rotelyx://`. A
  /// link to `https://rotelyx.com/i#...` is a Universal Link, and iOS delivers
  /// one as a user activity instead. An application that implements only the
  /// first opens for its own scheme and sends every web link to Safari, which
  /// is what happened here: the entitlement named the domain, the site served
  /// the association, and the link still went nowhere because nothing was
  /// listening on this side.
  ///
  /// # The fragment survives
  ///
  /// `webpageURL` is the whole link, and the invitation lives after the hash.
  /// It never reached a server on the way here: the phone recognised the domain
  /// and opened this instead of making the request at all.
  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL
    else {
      return super.application(
        application, continue: userActivity, restorationHandler: restorationHandler)
    }

    // Held when the engine is not up yet, exactly as a cold launch through
    // `open url:` is: a link that arrives before anything is listening must
    // not be pushed into nothing.
    if let links = links {
      links.invokeMethod("link", arguments: url.absoluteString)
    } else {
      launchedBy = url.absoluteString
    }
    return true
  }

  private var audio: CallAudio?
  private var camera: QrCamera?
  private var files: FilePicker?

  /// Held for the same reason as `files`: a channel handler that is the only
  /// reference to its object is a channel that stops working when the object
  /// is collected.
  private var keeper: SaveToPhotos?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Replying from the shade, and the only place a delegate can be set: iOS
    // reads it at launch and ignores one installed later.
    UNUserNotificationCenter.current().delegate = self
    Notifications.registerCategory()

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
        case "show": Notifications.show(call, result)
        case "clear": Notifications.clear(call, result)
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

      let bridge = WatchBridge()
      watch = bridge
      bridge.start(controller.binaryMessenger)

      Widgets.start(controller.binaryMessenger)
      BurnActivityChannel.start(controller.binaryMessenger)

      // Links from outside: an invitation somebody tapped, or the home screen
      // widget's `rotelyx://meet`.
      //
      // The contract is `lib/platform/incoming_link.dart`'s and was already
      // here for Android: `initial` is asked once for whatever started this
      // launch, and `link` is pushed for anything arriving while it runs.
      // Inventing a second channel would have replaced that handler and taken
      // invitations away from the platform where they already worked.
      let links = FlutterMethodChannel(name: "rotelyx/links",
                                       binaryMessenger: controller.binaryMessenger)
      self.links = links
      links.setMethodCallHandler { [weak self] call, result in
        guard call.method == "initial" else {
          result(FlutterMethodNotImplemented)
          return
        }
        // Answers once. A second call gets nothing even if the first found
        // something, which is what the Dart side documents.
        let waiting = self?.launchedBy
        self?.launchedBy = nil
        result(waiting)
      }

      let picker = FilePicker(host: controller)
      files = picker
      FlutterMethodChannel(name: FilePicker.channel,
                           binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler { call, result in picker.handle(call, result) }

      let photos = SaveToPhotos()
      keeper = photos
      FlutterMethodChannel(name: SaveToPhotos.channel,
                           binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler { call, result in photos.handle(call, result) }
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

  /// A reply typed into the notification itself.
  ///
  /// The application is running, because it is the one that posted this, so the
  /// text goes straight into the conversation. Nothing is opened and nothing is
  /// shown: a reply from the shade that pushes a screen in front of somebody is
  /// a reply nobody sends twice.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    guard response.actionIdentifier == Notifications.replyAction,
          let typed = response as? UNTextInputNotificationResponse,
          let conversation = response.notification.request.content
            .userInfo["conversation"] as? String,
          !conversation.isEmpty,
          let controller = window?.rootViewController as? FlutterViewController
    else {
      completionHandler()
      return
    }

    FlutterMethodChannel(name: AppDelegate.notifyChannelName,
                         binaryMessenger: controller.binaryMessenger)
      .invokeMethod("replied", arguments: [
        "conversationId": conversation,
        "text": typed.userText,
      ]) { _ in completionHandler() }
  }

  /// Shown even with the application in front.
  ///
  /// `alerts.dart` already decides whether a message is worth interrupting for,
  /// and it withholds the ones that are not. Letting iOS suppress the rest
  /// would overrule a decision made with more to go on.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
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

  /// What the notification extension files a wake that found nothing under.
  ///
  /// Spelled again here rather than shared, because the extension is a separate
  /// binary and one string is a smaller price than a framework between them.
  /// It has to match `NotificationService.quietThread`.
  private static let quietThread = "rotelyx.wake.nothing"

  override func applicationDidBecomeActive(_ application: UIApplication) {
    // Clear the blank wakes on the way in.
    //
    // The extension already takes away the one before it each time it runs, so
    // there is rarely more than one. This is for the person who opens the
    // application and should not be shown a leftover notification about
    // nothing while they are looking at the thing it was about.
    let centre = UNUserNotificationCenter.current()

    // The push's own notice goes too. It says a message arrived, and somebody
    // opening the application is about to see which.
    centre.removeDeliveredNotifications(withIdentifiers: [Notifications.wakeNotice])

    centre.getDeliveredNotifications { delivered in
      let blanks = delivered
        .filter { $0.request.content.threadIdentifier == AppDelegate.quietThread }
        .map { $0.request.identifier }
      guard !blanks.isEmpty else { return }
      centre.removeDeliveredNotifications(withIdentifiers: blanks)
    }

    super.applicationDidBecomeActive(application)
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
