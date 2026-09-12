import Foundation

/// Asking the mailbox whether anything is waiting, from inside the extension.
///
/// # Why this exists
///
/// A push carries nothing. The server sends the same wake whether or not
/// anything arrived, so that the pattern Apple sees says nothing about who was
/// messaged, and it marks every one `decoy` to say so. Which leaves the device
/// as the only party that can tell the difference, and the extension as the
/// only part of the device that is running.
///
/// # What it needs, and what it does not
///
/// The tags this device listens on, which the application writes into the
/// shared container whenever it subscribes. Nothing else: no key, no session,
/// no store. It subscribes to those tags and reads the count out of the
/// `ready` reply, which is the mailbox saying how many envelopes it is holding
/// under them.
///
/// It never collects. Collection removes an envelope from the mailbox, and an
/// envelope removed by a process that cannot decrypt it is a message deleted
/// before anybody read it. The subscription is opened, counted and dropped.
///
/// # The deadline
///
/// iOS allows about thirty seconds. This gives itself ten, because a
/// notification that arrives late is worse than one that arrives generic, and
/// because `serviceExtensionTimeWillExpire` firing means the untouched
/// notification is shown instead.
enum Waiting {

    /// The file the application leaves. See `publishListeningTags` in Dart.
    private struct Listening: Decodable {
        let mailbox: String
        let tags: [String]
    }

    private static let group = "group.com.rotelyx.ios"
    private static let deadline: TimeInterval = 10

    /// Hand back how many envelopes are waiting, or nil when that could not be
    /// asked at all.
    ///
    /// # Why the two are no longer the same answer
    ///
    /// Every failure used to return zero: no container, no tags, no network,
    /// no answer inside ten seconds. The reasoning was that showing a
    /// notification whenever the network was slow is worse than showing none.
    ///
    /// It is not, because "none" is not what happens. iOS cannot be told to
    /// drop a notification without an entitlement this application does not
    /// have, so handing back empty content posts a banner with no title and no
    /// text. The choice was never between a wrong notification and silence. It
    /// was between a wrong notification and a blank one, and the blank is
    /// worse: it says nothing, it cannot be acted on, and it arrives exactly
    /// when the application is closed and the network is least likely to
    /// answer, which is to say all the time.
    ///
    /// So a failure is nil now, and the caller shows the message rather than
    /// pretending to know there was none.
    static func check(_ done: @escaping (Int?) -> Void) {
        guard
            let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: group),
            let data = try? Data(contentsOf: container.appendingPathComponent("listening.json")),
            let listening = try? JSONDecoder().decode(Listening.self, from: data),
            !listening.tags.isEmpty,
            let url = URL(string: listening.mailbox)
        else {
            done(nil)
            return
        }

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)

        // Called once, whatever happens first: an answer, a failure, or the
        // deadline. Without this the socket outliving the extension would hand
        // back a count nobody is waiting for any more.
        var finished = false
        let finish: (Int?) -> Void = { count in
            guard !finished else { return }
            finished = true
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            done(count)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { finish(nil) }

        socket.resume()

        let request: [String: Any] = ["op": "subscribe", "tags": listening.tags]
        guard
            let body = try? JSONSerialization.data(withJSONObject: request),
            let text = String(data: body, encoding: .utf8)
        else {
            finish(nil)
            return
        }

        socket.send(.string(text)) { error in
            if error != nil {
                finish(nil)
                return
            }
            receive(socket, finish)
        }
    }

    /// Read replies until the one that carries the count.
    ///
    /// The mailbox delivers the backlog before it says `ready`, so envelopes
    /// arrive first and are ignored: they are not acknowledged and stay in the
    /// mailbox for the application. `ready` carries `waiting`, which is the
    /// number this came to find.
    private static func receive(
        _ socket: URLSessionWebSocketTask,
        _ finish: @escaping (Int?) -> Void
    ) {
        socket.receive { result in
            switch result {
            case .failure:
                finish(nil)
            case .success(let message):
                guard
                    case .string(let text) = message,
                    let data = text.data(using: .utf8),
                    let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    receive(socket, finish)
                    return
                }

                switch reply["op"] as? String {
                case "ready":
                    finish(reply["waiting"] as? Int ?? 0)
                case "error":
                    finish(nil)
                default:
                    // An envelope, or something this does not handle. Keep
                    // reading: `ready` comes after the backlog.
                    receive(socket, finish)
                }
            }
        }
    }
}
