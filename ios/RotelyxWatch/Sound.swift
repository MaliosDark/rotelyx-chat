import AVFoundation

/// The Rotelyx tone, on the wrist.
///
/// # Why this exists when watchOS has no custom notification sound
///
/// It has none, and that is not what this is. A notification forwarded from the
/// phone is announced by the system with the system's own tone, and no
/// application can change it.
///
/// This is the other case: the application is open on the wrist and a message
/// arrives. Nothing about that is a notification — it is audio, played by an
/// application that is running, and an application that is running may play
/// whatever it likes. So the one moment watchOS leaves open is the one moment
/// Rotelyx can sound like itself.
///
/// The same file Android's notification channel plays and the same file
/// `Notifications.swift` now gives iOS, so the tone is one tone across three
/// screens rather than three tones that happen to belong to one application.
enum Sound {

    /// Held rather than made each time. An `AVAudioPlayer` that goes out of
    /// scope stops, which on a sound this short means it is never heard at all.
    private static var player: AVAudioPlayer?

    /// A message arrived while somebody was looking at the watch.
    static func message() {
        guard let url = Bundle.main.url(forResource: "message", withExtension: "wav")
        else { return }

        do {
            // Ambient, and mixing. A tone this long has no business stopping
            // music or taking a call's audio away from it: the category that
            // interrupts is for something a person chose to listen to, and
            // nobody chose this.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            Sound.player = player
            player.play()
        } catch {
            // Silence is an acceptable outcome. The haptic has already fired
            // and it is the half a wrist actually notices.
        }
    }
}
