import Foundation

/// What a widget is allowed to draw, read from the container the application
/// writes.
///
/// Two of them, because a home screen and a lock screen are not the same
/// question. A home screen is behind the passcode, so whoever is looking has
/// already been let in. A lock screen is read by whoever the phone is lying in
/// front of. The person sets them separately, and the application only writes
/// what each is permitted to carry — so a widget cannot leak what its setting
/// refused, because the refused thing never reached this container.
struct Glance {
    let waiting: Int
    let who: String

    static let empty = Glance(waiting: 0, who: "")

    static func read(_ surface: String) -> Glance {
        guard let store = UserDefaults(suiteName: "group.com.rotelyx.ios") else {
            return .empty
        }
        return Glance(
            waiting: store.integer(forKey: "\(surface).waiting"),
            who: store.string(forKey: "\(surface).who") ?? "")
    }
}
