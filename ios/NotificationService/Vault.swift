import Foundation

/// What the application keeps, read from the extension.
///
/// # Why this exists
///
/// A notification that says "New message" is one somebody has to open the
/// application to read, which is the thing they were trying not to do. To say
/// more, the extension has to open the message, and to open a message it needs
/// what the application holds: the key, and the sealed session for the
/// conversation the message arrived in.
///
/// # What it reads, and what it must never write
///
/// Reads. Nothing here writes, and that is the whole safety argument rather
/// than tidiness. The sealed session on disk is an MLS state, and two
/// processes advancing one is the failure this application has spent the
/// longest on. The extension unseals a copy, reads one envelope with it, and
/// throws it away: the file is untouched, the envelope is not acknowledged,
/// and the application receives that message properly the next time it runs.
///
/// # Why parsing the application's storage is acceptable here
///
/// It is one JSON object in a container only these two processes can open, and
/// three keys of it are used. The alternative was a second copy of the same
/// data written for the extension's benefit, which is a second thing to keep
/// in step and a second place for a session to go stale.
enum Vault {

    private static let group = "group.com.rotelyx.ios"
    private static let file = "GetStorage.gs"

    /// Everything the extension needs, or nil when there is nothing to read.
    struct Contents {
        /// Thirty two bytes, base64url without padding, as the application
        /// wrote them. Handed to the engine rather than interpreted here.
        let deviceKey: String

        /// The conversations this device holds, newest activity first where
        /// the index says so.
        let conversations: [String]

        /// Sealed sessions, by conversation.
        let sessions: [String: String]

        /// Where to ask. The application's own choice where it has one, and
        /// the build's default otherwise, which is the same order the
        /// application resolves it in.
        let mailbox: String

        /// The constellation's directory, where the build has one.
        ///
        /// A conversation's mail is kept on two mailboxes of three and which
        /// two is worked out from the tag and this. Without it the extension
        /// asks one mailbox and finds the message about two times in three.
        let directory: String?

        /// Whether the person asked for the message to be shown.
        let showContent: Bool
    }

    static func read() -> Contents? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group),
            let data = try? Data(contentsOf: container.appendingPathComponent(file)),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let key = row["rotelyx.devicekey"] as? String, !key.isEmpty
        else {
            // A vault made by a passphrase, from before the device key, or one
            // that has never been opened. Nothing here can open it and nothing
            // should try: what that vault protects is what somebody knows.
            return nil
        }

        let ids = (row["rotelyx.index"] as? [Any])?.compactMap { $0 as? String } ?? []

        var sessions: [String: String] = [:]
        for id in ids {
            if let blob = row["rotelyx.session.\(id)"] as? String {
                sessions[id] = blob
            }
        }

        return Contents(
            deviceKey: key,
            conversations: ids,
            sessions: sessions,
            // `listening.json` carries the one the application last used,
            // which is the resolved answer rather than a setting that may be
            // absent. See `apple_push_native.dart`.
            mailbox: Self.listening(in: container)?["mailbox"] as? String ?? "",
            directory: Self.listening(in: container)?["directory"] as? String,
            // Absent reads as on, which is what the application defaults to.
            // Somebody who has never touched the setting gets what the rest of
            // the application already gives them on a locked screen.
            showContent: (row["rotelyx.previews"] as? Bool) ?? true
        )
    }

    /// What the application left for the extension: the mailbox it last spoke
    /// to, the tags it listens on, and the constellation's directory.
    private static func listening(in container: URL) -> [String: Any]? {
        guard let data = try? Data(
            contentsOf: container.appendingPathComponent("listening.json")),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return row
    }

    /// What a conversation is called, for the line above the message.
    ///
    /// The conversation log is sealed, so the title is not read from it here:
    /// opening that would be a second thing to unseal for a word. The engine
    /// names the author of the message instead, which is the more useful of
    /// the two in a group and the same one in a pair.
    static func title(for id: String) -> String? { nil }
}
