import SwiftUI

/// Rotelyx on a wrist.
///
/// # What this is, and what it deliberately is not
///
/// A second screen onto a conversation that lives on the phone. It holds no
/// key, no session and no mailbox connection, and it never speaks to a server.
/// Everything here arrived on the phone, was opened there, and came across
/// Apple's device-to-device link already in the clear. A stolen watch yields
/// whatever was last shown on it and no way to read anything else.
///
/// The alternative was the engine on the watch, with its own identity and
/// subscription. It would work away from the phone, and it would also put two
/// devices on one MLS ratchet, which loses messages permanently. The same
/// warning is in `docs/PUSH.md` about the notification extension.
@main
struct RotelyxWatchApp: App {
    @StateObject private var phone = Phone()

    var body: some Scene {
        WindowGroup {
            // `NavigationView`, not `NavigationStack`, which is watchOS 9.
            NavigationView {
                ConversationList()
            }
            .environmentObject(phone)
        }
    }
}
