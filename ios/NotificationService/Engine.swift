import Foundation
import RotelyxEngine

/// The engine, from inside the notification extension.
///
/// # Why an extension has one at all
///
/// A notification that says "New message" is a notification somebody has to
/// open the application to read, and the application is what they were trying
/// not to have to open. Every messenger that matters shows the sender and the
/// text; this one could not, because the message is encrypted and the only
/// thing that can open it is the engine.
///
/// # Why this is safe, which it was not before
///
/// Two processes moving one MLS session is the failure this application has
/// spent the longest on, so the rule here is absolute: **nothing is written
/// down and nothing is acknowledged.** The session is unsealed from the blob,
/// used to read one envelope, and thrown away. The blob on disk is untouched
/// and the envelope stays in the mailbox, so when the application next opens
/// it receives that message properly, advances its own ratchet and
/// acknowledges it then.
///
/// The cost is decrypting twice. The alternative was the epochs of two
/// devices drifting apart, which cost a week.
enum Engine {

    /// Whether the engine is here and answering.
    static var version: String? {
        guard let raw = rotelyx_abi_version() else { return nil }
        return String(cString: raw)
    }

    /// One call, as the same JSON the rest of the application speaks.
    ///
    /// Returns the `result` field, or nil when the engine refused. A refusal
    /// is not worth reporting from here: the notification falls back to
    /// saying a message arrived, which is what it said before any of this.
    static func call(_ request: [String: Any]) -> Any? {
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: body, encoding: .utf8)
        else { return nil }

        var reply: UnsafeMutablePointer<CChar>?
        let code = text.withCString { rotelyx_call($0, &reply) }

        guard let reply = reply else { return nil }
        defer { rotelyx_string_free(reply) }
        guard code == 0 else { return nil }

        guard let data = String(cString: reply).data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["ok"] as? Bool == true
        else { return nil }

        return parsed["result"]
    }
}
