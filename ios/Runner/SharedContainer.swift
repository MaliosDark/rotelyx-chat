import Foundation

/// The one place the application and its notification extension both reach.
///
/// # Why anything is shared at all
///
/// A push arrives in the extension's process. The conversation it is about is
/// in the application's. On iOS those are two processes with two sandboxes, and
/// without an App Group they cannot see each other's files at all: the
/// extension would be able to say "something arrived" and nothing more, forever.
///
/// # What lives here, and what deliberately does not
///
/// The encrypted conversation log lives here. It is the same sealed blob the
/// Android build writes, unreadable without the vault key, and putting it in a
/// shared container does not make it readable by anything except the two
/// processes named in the entitlement.
///
/// The vault key does **not** live here, and that is a decision rather than an
/// oversight. Reaching it from an extension means the iOS Keychain with
/// `kSecAttrAccessibleAfterFirstUnlock`, because an extension woken on a locked
/// screen cannot ask anybody for a passphrase. That would put the key at rest
/// on the device, which is a real change to what a seized phone yields, and it
/// is written up in `docs/PUSH.md` rather than made quietly here.
///
/// Until that decision is taken, the extension shows who a message is from and
/// not what it says, which is exactly what a locked screen with previews turned
/// off shows anyway.
enum SharedContainer {

    /// Named in both entitlement files. A mismatch between them and this string
    /// produces a nil container and an application that silently stops keeping
    /// history, so it is one constant and not three literals.
    static let group = "group.com.rotelyx.ios"

    /// Where both processes may read and write.
    ///
    /// Nil when the App Group is not provisioned, which happens on a build
    /// signed with a profile that does not carry it. The caller falls back to
    /// the application's own container: history still works, and only the
    /// extension loses its view of it.
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// The path Dart hands to its storage layer.
    ///
    /// Marked as excluded from iCloud on the way out. See [keepOutOfBackups].
    static var path: String? {
        guard let url else { return nil }
        keepOutOfBackups(url)
        return url.path
    }

    /// Tell iOS that none of this may go to iCloud.
    ///
    /// # Why
    ///
    /// An App Group container is backed up to iCloud by default, and what is in
    /// this one is the conversation history and the sealed sessions. Since the
    /// vault stopped asking for a passphrase, the key that opens them is beside
    /// them, so a backup carries the lock and the key together into somebody
    /// else's cloud, and the person it belongs to has no way of knowing it is
    /// there.
    ///
    /// The Android build refuses the same thing in its manifest, through
    /// `allowBackup` and `dataExtractionRules`. This is the half that makes the
    /// two platforms agree.
    ///
    /// # What it costs, said plainly
    ///
    /// Somebody restoring a new iPhone from iCloud arrives with no history.
    /// That is what this protocol already promises: forward secrecy means
    /// nobody keeps the material to rebuild a conversation, so there was never
    /// an honest way to carry it across. Export from inside the application is
    /// the answer for anybody who wants a copy, and it is theirs.
    ///
    /// Set on every launch rather than once. The flag lives on the file system
    /// and a container recreated by a restore, a reinstall or an App Group
    /// being reprovisioned comes back without it, and a flag that is only ever
    /// set once is one that silently stops being true.
    ///
    /// A failure here is recorded and not raised: an application that refuses
    /// to start because it could not set a file attribute is worse than one
    /// that starts.
    static func keepOutOfBackups(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            NSLog("rotelyx: could not exclude the container from iCloud: \(error)")
        }
    }
}
