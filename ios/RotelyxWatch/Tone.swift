import SwiftUI

/// The palette, the same numbers `lib/ui/theme.dart` uses.
///
/// Copied rather than shared, because there is nothing to share it through: the
/// watch does not run Dart and the phone does not run this. Copied deliberately
/// and in one place, so that a colour changing on the phone has exactly one file
/// to change here rather than a handful of literals scattered through views.
///
/// Only the dark half exists. watchOS has no light mode.
enum Tone {
    /// The brand violet. What you said, on both screens.
    static let accent = Color(red: 0x6A / 255, green: 0x31 / 255, blue: 0xEE / 255)

    /// What they said. `dRaised` on the phone — a card lifted off the backdrop,
    /// which on a watch is the only thing separating a bubble from the black
    /// the screen is painted with when it is off.
    static let raised = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x23 / 255)

    /// The burn. Not a second accent: it belongs to one event and appears
    /// nowhere else, which is what keeps it meaning something. The same number
    /// as `Tone.fire` on the phone.
    static let fire = Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x18 / 255)

    static let text = Color(red: 0xF2 / 255, green: 0xF1 / 255, blue: 0xF5 / 255)
    static let muted = Color(red: 0x9B / 255, green: 0x98 / 255, blue: 0xA8 / 255)
}
