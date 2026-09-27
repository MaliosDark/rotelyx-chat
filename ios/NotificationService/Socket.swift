import Foundation

/// One connection, to one conversation's addresses.
///
/// # The rule this keeps
///
/// A connection subscribed to two conversations has told the mailbox those
/// conversations belong to one device, and the mailbox's whole privacy
/// argument is that it cannot know that. The application keeps this rule with
/// an object every subscription passes through; the extension keeps it by
/// having one function, which takes one conversation's tags and is called
/// again for the next.
///
/// # What comes back
///
/// The envelopes waiting under those tags, still sealed. Nothing is
/// acknowledged: acknowledging is how the mailbox is told to let go, and
/// letting go of something only this extension has seen would lose it. The
/// application acknowledges when it has the message written down.
enum Socket {

    /// Collect what is waiting, or nothing.
    ///
    /// Nil is never handed back: an empty array says the mailbox answered and
    /// had nothing, and the caller cannot act differently on the two.
    static func collect(
        mailbox: String,
        tags: [String],
        within: TimeInterval = 8,
        done: @escaping ([String]) -> Void
    ) {
        guard !tags.isEmpty, let url = URL(string: mailbox) else {
            done([])
            return
        }

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)

        var envelopes: [String] = []
        var finished = false
        let finish: () -> Void = {
            guard !finished else { return }
            finished = true
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            done(envelopes)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + within) { finish() }

        socket.resume()

        // Sixty four is the mailbox's ceiling for one subscription and forty
        // is what a conversation's lookback comes to, so this is one frame.
        let request: [String: Any] = ["op": "subscribe", "tags": Array(tags.prefix(64))]
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: body, encoding: .utf8)
        else {
            finish()
            return
        }

        socket.send(.string(text)) { error in
            if error != nil {
                finish()
                return
            }
            read()
        }

        func read() {
            socket.receive { result in
                guard !finished else { return }
                switch result {
                case .failure:
                    finish()
                case .success(let message):
                    guard case .string(let raw) = message,
                          let data = raw.data(using: .utf8),
                          let frame = try? JSONSerialization.jsonObject(with: data)
                              as? [String: Any]
                    else {
                        read()
                        return
                    }

                    switch frame["op"] as? String {
                    case "envelope":
                        if let envelope = frame["envelope"] as? String {
                            envelopes.append(envelope)
                        }
                        read()
                    case "ready":
                        // The backlog is delivered before `ready`, so by here
                        // everything waiting has arrived.
                        finish()
                    case "error":
                        finish()
                    default:
                        read()
                    }
                }
            }
        }
    }
}
