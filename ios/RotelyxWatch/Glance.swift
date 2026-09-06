import Foundation
import WidgetKit

/// What the face is allowed to say, and where it is kept.
///
/// # Why anything is stored on the watch at all
///
/// Every other screen here asks the phone and keeps nothing. A complication
/// cannot: it is drawn by a separate process when the face is drawn, long after
/// the watch application last ran and with no phone in reach, and `WCSession`
/// is not available to it. Something has to be written down or the face has
/// nothing to show.
///
/// So this is the one thing on the watch that survives the application closing,
/// and it is kept to the least that can fill a complication: how many
/// conversations are waiting and who the most recent one is with. No message
/// text, ever: a preview on a watch face is a message published to the room.
///
/// It is not sealed, because a shared container the operating system already
/// isolates per application is what a complication can read and a passphrase is
/// not something a face can be asked for. What it holds is a number and a name
/// the person chose for somebody. That is the honest description; anyone who
/// needs less can leave the complication off the face.
struct Glance: Codable {
    /// Conversations with something new in them.
    let waiting: Int

    /// Who the most recent one is with, or empty when there is none.
    let who: String

    static let empty = Glance(waiting: 0, who: "")

    // MARK: - Where it lives

    static let group = "group.com.rotelyx.ios"
    private static let key = "rotelyx.glance"

    private static var store: UserDefaults? {
        UserDefaults(suiteName: Glance.group)
    }

    /// Write it, and tell the face to redraw.
    ///
    /// Reloading is not optional: a complication is not asked for its timeline
    /// again because something changed, only because it said when to ask. Left
    /// out, the face keeps yesterday's number until the system next feels like
    /// it.
    static func write(_ glance: Glance) {
        guard let data = try? JSONEncoder().encode(glance) else { return }
        store?.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Read it, or the empty one. A face with nothing to say still has to draw.
    static func read() -> Glance {
        guard let data = store?.data(forKey: key),
              let glance = try? JSONDecoder().decode(Glance.self, from: data)
        else { return .empty }
        return glance
    }
}
