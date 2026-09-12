import Foundation

/// What the last push wake did, written where the application can read it.
///
/// # Why this exists
///
/// A notification extension runs for a few seconds in its own process, with no
/// console anybody is watching, and then dies. When one of them shows the
/// wrong thing there is no way to find out why: the person sees a banner, the
/// developer sees nothing, and the conversation that follows is both of them
/// guessing. That went on for days over one blank notification.
///
/// So each wake leaves a line behind. The application shows it in Settings,
/// and the question "what did your phone actually do" has an answer somebody
/// can read out.
///
/// # What it holds, and what it must never hold
///
/// When it ran, whether the server called it a decoy, what the mailbox said
/// was waiting, and which of the three endings happened. No tag, no
/// conversation, no sender, not a word of any message. It is a note about this
/// application's own plumbing and it stays that way: this file is in the
/// shared container, the container survives being backed up, and a diagnostic
/// that grows a field naming who wrote to you is a diagnostic that has turned
/// into a log of your correspondents.
enum LastWake {

    private static let group = "group.com.rotelyx.ios"
    private static let name = "last-wake.json"

    /// How the wake ended.
    enum Ending: String {
        /// A ticket, so a message exists. Shown without asking anybody.
        case ticket

        /// The mailbox answered and there was something there.
        case waiting

        /// The mailbox answered and there was nothing.
        case nothing

        /// The mailbox could not be asked: no tags, no network, or too slow.
        case unknown

        /// Thirty seconds ran out.
        case expired
    }

    static func write(decoy: Bool, waiting: Int?, ending: Ending) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return }

        var row: [String: Any] = [
            "at": Date().timeIntervalSince1970 * 1000,
            "decoy": decoy,
            "ending": ending.rawValue,
        ]
        if let waiting = waiting { row["waiting"] = waiting }

        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
        try? data.write(to: container.appendingPathComponent(name), options: .atomic)
    }
}
