import ActivityKit
import Foundation

/// What a burning message shows while it burns.
///
/// Deliberately thin. A Live Activity sits on a locked screen and in the
/// Dynamic Island, where anybody near the phone can read it, so what travels is
/// a deadline and a count: never who it is from and never a word of what it
/// says. The countdown is drawn by the system from `burnsAt`, which means the
/// number ticks without this application waking up to move it.
///
/// Marked for 16.1 because that is when Live Activities arrived, and this
/// application still runs on 15. A phone too old for one simply never sees a
/// countdown; everything else about a burning message is unchanged.
@available(iOS 16.1, *)
struct BurnAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Equatable {
        /// When the earliest one goes.
        var burnsAt: Date

        /// How many are counting down, so a second one arriving does not need a
        /// second activity crowding the island.
        var waiting: Int
    }
}

