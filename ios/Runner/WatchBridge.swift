import Flutter
import Foundation
import WatchConnectivity

/// The phone's half of the watch.
///
/// # What the watch is, and what it deliberately is not
///
/// It is another screen, and nothing else. It holds no key, no session and no
/// mailbox connection, and it never speaks to a server. Everything it shows
/// arrived here first, was opened here, and was handed across already in the
/// clear over Apple's device-to-device link. A stolen watch yields a cache of
/// whatever was last on it and no way to read anything else, which is the
/// difference between a second screen and a second phone.
///
/// The alternative was a watch with the engine on it, its own identity and its
/// own subscription. It would work away from the phone, and it would also mean
/// two devices stepping one MLS ratchet, which loses messages permanently. See
/// the same warning about the notification extension in `docs/PUSH.md`.
///
/// # Why the phone answers rather than pushes
///
/// A watch asks when somebody raises their wrist. Pushing the whole list every
/// time anything changes spends the phone's battery to keep a screen nobody is
/// looking at up to date. So this answers questions, and pushes only one thing:
/// a message that has just arrived, which is the case where the watch has to
/// know without being asked.
class WatchBridge: NSObject, WCSessionDelegate {

    static let channel = "rotelyx/watch"

    /// Asking Dart for what the watch wants. Nil until the engine is up.
    private var toDart: FlutterMethodChannel?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func start(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: WatchBridge.channel, binaryMessenger: messenger)
        toDart = channel

        // The same channel in the other direction, for the two things a wrist
        // cannot find out by asking. Dart decides what they are; this carries
        // them.
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "notify" else {
                result(FlutterMethodNotImplemented)
                return
            }
            self?.arrived(call.arguments as? [String: Any] ?? [:])
            result(nil)
        }

        guard let session = session else { return }
        session.delegate = self
        session.activate()
    }

    /// A message arrived while the phone was awake. Tell the watch, if one is
    /// there and reachable.
    ///
    /// `transferUserInfo` rather than `sendMessage`: it queues and survives the
    /// watch being asleep, which is the ordinary state of a watch.
    func arrived(_ payload: [String: Any]) {
        guard let session = session, session.activationState == .activated else { return }
        guard session.isPaired && session.isWatchAppInstalled else { return }
        session.transferUserInfo(payload)
    }

    // MARK: - Questions from the watch

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let op = message["op"] as? String else {
            replyHandler(["error": "no op"])
            return
        }

        // Straight through to Dart, which owns the store and the session. This
        // file translates between two transports and decides nothing.
        DispatchQueue.main.async { [weak self] in
            guard let toDart = self?.toDart else {
                replyHandler(["error": "not ready"])
                return
            }

            toDart.invokeMethod(op, arguments: message["args"]) { answer in
                if let answer = answer as? [String: Any] {
                    replyHandler(answer)
                } else if answer is FlutterError {
                    replyHandler(["error": "refused"])
                } else {
                    replyHandler(["ok": true])
                }
            }
        }
    }

    // MARK: - WCSessionDelegate, the parts iOS requires

    func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {}

    /// Both are required on iOS and both mean the same thing here: the watch
    /// this phone was talking to is gone. Reactivating is what lets a second
    /// watch be paired without restarting the application.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
