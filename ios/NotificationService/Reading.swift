import Foundation

/// Finding the message a wake was about, and reading it.
///
/// # One connection asks about one conversation
///
/// That rule is the mailbox's whole privacy argument and it is kept here as
/// strictly as in the application. A connection subscribed to two
/// conversations has told the mailbox those conversations belong to one
/// device, and from there to somebody's social graph is a matter of waiting.
/// So this opens a socket per conversation, one at a time, and closes it
/// before opening the next.
///
/// One at a time rather than all at once for a second reason: the mailbox
/// allows ten concurrent connections from one address, and the application may
/// be holding several of them while this runs.
///
/// # Nothing is written and nothing is acknowledged
///
/// The session is unsealed from a copy of the blob, used to read, and thrown
/// away. The envelope stays in the mailbox. The application receives that
/// message properly when it next runs, advances its own ratchet and
/// acknowledges it then.
///
/// This is what makes reading here safe at all. Two processes advancing one
/// MLS session is the failure this application has spent the longest on, and
/// the price of avoiding it is decrypting twice, which is nothing.
enum Reading {

    /// What was found, ready to show.
    struct Message {
        let from: String
        let text: String

        /// How many were waiting in that conversation, which is what the
        /// notification says when there is more than one.
        let waiting: Int
    }

    /// How long the whole search may take.
    ///
    /// An extension gets about thirty seconds and `serviceExtensionTimeWillExpire`
    /// is what happens if it overruns, which shows the server's own wording
    /// rather than the message. Well inside it, because a phone on a slow
    /// network is exactly when this runs.
    private static let deadline: TimeInterval = 18

    /// The most conversations to look through before giving up.
    ///
    /// Each is a connection, and the search is sequential, so this is the
    /// thing that decides whether the deadline is met. The conversations most
    /// recently written to come first, and a message in a quiet one is found
    /// when the application opens.
    private static let most = 6

    /// Look for what arrived, and read it.
    ///
    /// Hands back nil when there is nothing to show, which is the ordinary
    /// answer for a scheduled wake and the answer whenever anything at all
    /// goes wrong. The caller falls back to saying a message arrived.
    static func find(_ done: @escaping (Message?) -> Void) {
        guard let vault = Vault.read(), vault.showContent else {
            done(nil)
            return
        }

        guard let key = Engine.call(["op": "key.fromPlatformKey", "key": vault.deviceKey])
            as? Int
        else {
            done(nil)
            return
        }

        let started = Date()
        var remaining = Array(vault.conversations.prefix(most))

        // Called once, whatever finishes first.
        var finished = false
        let finish: (Message?) -> Void = { found in
            guard !finished else { return }
            finished = true
            _ = Engine.call(["op": "key.free", "handle": key])
            done(found)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { finish(nil) }

        func next() {
            guard !finished else { return }
            guard Date().timeIntervalSince(started) < deadline - 3,
                  let id = remaining.first
            else {
                finish(nil)
                return
            }
            remaining.removeFirst()

            guard let blob = vault.sessions[id],
                  let session = Engine.call([
                      "op": "session.unseal", "blob": blob, "key": key,
                  ]) as? Int
            else {
                next()
                return
            }

            // The forty hour lookback, as the application uses when it opens a
            // conversation. This is the cold case by definition: the
            // application has not been running, so the recent buckets are
            // exactly where an unread message is.
            let tags = (Engine.call([
                "op": "session.myPollingTags",
                "handle": session,
                "timeBucket": Int(Date().timeIntervalSince1970) / 3600,
                "lookback": 39,
            ]) as? [Any])?.compactMap { $0 as? String } ?? []

            if tags.isEmpty {
                _ = Engine.call(["op": "session.free", "handle": session])
                next()
                return
            }

            // Where this conversation's mail is kept.
            //
            // A constellation holds each tag on two mailboxes of three, and
            // which two is worked out from the tag and the directory by the
            // same engine both ends use. Asking the wrong one finds nothing
            // and says "New message", which is the failure this whole file
            // exists to remove, so it is worth the one call.
            //
            // The first is enough because both replicas hold it. An empty
            // answer means this build cannot place, and then the mailbox the
            // application last used is the right guess.
            var ask = vault.mailbox
            if let directory = vault.directory, let first = tags.first,
               let placed = Engine.call([
                   "op": "directory.placement",
                   "directory": directory,
                   "tag": first,
               ]) as? [Any],
               let best = placed
                   .compactMap({ ($0 as? [String: Any])?["url"] as? String })
                   .first
            {
                ask = best
            }

            Socket.collect(mailbox: ask, tags: tags) { envelopes in
                var found: Message?
                var counted = 0

                for envelope in envelopes {
                    guard let opened = Engine.call([
                        "op": "session.receive",
                        "handle": session,
                        "message": envelope,
                    ]) as? [String: Any] else { continue }

                    guard opened["kind"] as? String == "message",
                          let text = opened["text"] as? String
                    else { continue }

                    // Control messages travel as messages and are not ones. A
                    // read receipt is not worth waking somebody for, which is
                    // the same rule the application keeps.
                    if text.hasPrefix("rx-signal\u{001F}") { continue }

                    counted += 1
                    if found == nil {
                        found = Message(
                            from: opened["from"] as? String ?? "",
                            text: text,
                            waiting: 0)
                    }
                }

                // Thrown away. Nothing is sealed back and nothing is
                // acknowledged: see the note at the top of this file.
                _ = Engine.call(["op": "session.free", "handle": session])

                if let found = found {
                    finish(Message(from: found.from, text: found.text, waiting: counted))
                    return
                }
                next()
            }
        }

        next()
    }
}
