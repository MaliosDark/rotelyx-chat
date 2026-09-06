import Foundation
import WatchKit

/// What the watch does instead of a sound.
///
/// # Why there is no custom sound here, and this is not a shortcut
///
/// watchOS does not let an application choose the noise it makes. A watch
/// notification is the phone's notification mirrored, and it plays whatever the
/// phone's alert plays; the only signal a watch application picks for itself is
/// a haptic, and the taps are audible in a quiet room. So the Rotelyx signature
/// on a wrist is a rhythm rather than a tone.
///
/// The rhythm is the point. `.notification` alone is what every application on
/// the watch uses, and a person who feels it has learned nothing about who
/// wants them. A double tap is distinguishable without looking, which is the
/// only thing a haptic can usefully be.
enum Haptics {

    /// A message arrived. Two taps, a beat apart.
    ///
    /// The delay is what makes it two rather than one: haptics fired in the same
    /// runloop turn are felt as a single longer buzz, which is the system alert
    /// again and tells nobody anything.
    static func arrived() {
        play(.notification)
        after(0.22) { play(.click) }
    }

    /// Sent from the wrist. One tap, and a light one: an acknowledgement should
    /// not feel like an interruption.
    static func sent() {
        play(.click)
    }

    /// Somebody scanned the code and the conversation exists now.
    static func paired() {
        play(.success)
        after(0.18) { play(.click) }
    }

    /// A message is destroying itself.
    ///
    /// Three taps, quickening and then stopping dead: something catches, takes,
    /// and is gone. It is the only rhythm in the application that ends rather
    /// than resolves, which is what makes it recognisable without looking, and
    /// looking is exactly what somebody may not be doing when a message burns
    /// on their wrist.
    static func burning() {
        play(.directionDown)
        after(0.16) { play(.directionDown) }
        after(0.26) { play(.failure) }
    }

    /// The phone refused, or is not there.
    static func failed() {
        play(.failure)
    }

    private static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    private static func after(_ seconds: TimeInterval, _ run: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: run)
    }
}
