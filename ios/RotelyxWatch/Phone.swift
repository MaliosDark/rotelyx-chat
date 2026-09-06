import Foundation
import WatchConnectivity

/// One conversation, as much of it as a wrist needs.
struct Conversation: Identifiable, Decodable {
    let id: String
    let title: String
    let last: String
    let at: Double
}

/// One message.
struct Message: Identifiable, Decodable {
    var id: String { "\(at)-\(mine)-\(text.hashValue)" }
    let text: String
    let mine: Bool
    let at: Double

    /// Whether it destroys itself at all.
    ///
    /// Not the same question as when. A message set to expire that nobody has
    /// opened yet has no deadline running, and it still has to be marked: the
    /// flame warns about what the message is, not about a clock.
    let burns: Bool

    /// When this destroys itself, if it does.
    ///
    /// A moment rather than a countdown, so that a watch which was asleep wakes
    /// up already knowing the message should be gone rather than starting to
    /// count from whenever it happened to wake.
    let burnAt: Double?

    /// How long is left, or nil when nothing is counting.
    var burnsIn: TimeInterval? {
        guard let burnAt else { return nil }
        return max(0, burnAt / 1000 - Date().timeIntervalSince1970)
    }

    /// The moment itself, for a clock to count towards.
    var deadline: Date? {
        guard let burnAt, burnAt / 1000 > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: burnAt / 1000)
    }
}

/// The phone, asked rather than pushed to.
///
/// A watch is awake when a wrist is raised and asleep the rest of the time, so
/// this asks when a screen appears rather than keeping anything in step. The one
/// thing that arrives unasked is a message the phone has just received, which is
/// the case where the watch has to know without being asked.
final class Phone: NSObject, ObservableObject, WCSessionDelegate {

    @Published var conversations: [Conversation] = []
    @Published var messages: [Message] = []
    @Published var title = ""

    /// Why the last thing did not work, in the words the phone used.
    @Published var problem: String?

    /// Whether the phone is there at all. A watch out of range is the ordinary
    /// case rather than a failure, and saying so beats an empty list.
    @Published var reachable = false

    /// The meeting code being shown, in words, and the symbol to draw for it.
    /// Both nil until the phone has minted one. See `MyCode.swift`.
    @Published var code: String?
    @Published var codeRows: [String]?

    /// Somebody scanned the code and the phone finished the handshake.
    @Published var paired = false

    override init() {
        super.init()

        #if DEBUG
        // Store screenshots. A watch cannot be tapped from a script and the
        // phone it would ask is a simulator with no passphrase typed into it,
        // so the pictures the store wants would otherwise need a person.
        //
        // The same bargain as `-showCode` in `MyCode.swift`: real shapes, made
        // up content, and `#if DEBUG` so no released build carries either the
        // data or the flag that reaches it.
        if ProcessInfo.processInfo.arguments.contains("-sample") {
            conversations = Phone.sample
            reachable = true
            return
        }
        #endif

        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    #if DEBUG
    static let sample = [
        Conversation(id: "1", title: "Ana", last: "on my way", at: 0),
        Conversation(id: "2", title: "Marco", last: "did you see the thing?", at: 0),
        Conversation(id: "3", title: "Notes to self", last: "flat 4, code 2210", at: 0),
    ]

    static let sampleMessages = [
        Message(text: "are you at the station yet", mine: false, at: 1, burns: false, burnAt: nil),
        Message(text: "two minutes", mine: true, at: 2, burns: false, burnAt: nil),
        Message(text: "same platform as last time?", mine: false, at: 3, burns: false, burnAt: nil),
        Message(text: "yes, north end", mine: true, at: 4, burns: false, burnAt: nil),
        Message(text: "on my way", mine: false, at: 5, burns: false, burnAt: nil),

        // One that actually goes, so the burn can be watched rather than
        // trusted. Every sample carried `burnAt: nil` before this, which meant
        // the one piece of the watch nobody could see was also the one piece
        // nobody could test.
        Message(text: "flat 4, code 2210", mine: false, at: 6, burns: true,
                burnAt: Date().addingTimeInterval(25).timeIntervalSince1970 * 1000),
    ]

    private var sampling: Bool {
        ProcessInfo.processInfo.arguments.contains("-sample")
    }
    #endif

    func loadConversations() {
        #if DEBUG
        if sampling { conversations = Phone.sample; return }
        #endif
        ask(["op": "conversations"]) { [weak self] reply in
            guard let raw = reply["conversations"] else { return }
            let all = decode([Conversation].self, from: raw) ?? []
            self?.conversations = all

            // The face, which cannot ask anything itself. Both fields come
            // from the phone already filtered by the setting there, so an
            // empty name means the person asked for no name rather than that
            // nobody has written.
            Glance.write(Glance(
                waiting: reply["waiting"] as? Int ?? 0,
                who: reply["who"] as? String ?? ""))
        }
    }

    func open(_ conversation: Conversation) {
        messages = []
        title = conversation.title
        #if DEBUG
        if sampling { messages = Phone.sampleMessages; return }
        #endif
        ask(["op": "messages", "args": conversation.id]) { [weak self] reply in
            if reply["locked"] as? Bool == true {
                self?.problem = "This conversation has its own PIN. Open it on your phone."
                return
            }
            guard let raw = reply["messages"] else { return }
            self?.messages = decode([Message].self, from: raw) ?? []
        }
    }

    func send(_ text: String, to conversation: String) {
        ask(["op": "send", "args": ["id": conversation, "text": text]]) { [weak self] reply in
            if let error = reply["error"] as? String {
                self?.problem = error
                Haptics.failed()
            } else {
                Haptics.sent()
            }
        }
    }

    /// Take a message off the screen, because it has destroyed itself.
    ///
    /// Only here. The phone holds the conversation and has its own copy going
    /// at the same moment; this is the watch keeping its half of the promise
    /// rather than telling the phone anything.
    func forget(_ message: Message) {
        messages.removeAll { $0.id == message.id }
    }

    // MARK: - Meeting somebody

    /// Ask the phone for a meeting code and the symbol that draws it.
    ///
    /// The phone mints it, waits at the place it names, and keeps whatever
    /// comes of it. Nothing about the handshake happens here.
    func showCode() {
        code = nil
        codeRows = nil
        paired = false
        problem = nil

        ask(["op": "code"]) { [weak self] reply in
            if let error = reply["error"] as? String {
                self?.problem = error
                Haptics.failed()
                return
            }
            self?.code = reply["code"] as? String
            self?.codeRows = reply["rows"] as? [String]
        }
    }

    /// The screen went away. Tell the phone to stop listening for the answer.
    func stopCode() {
        code = nil
        codeRows = nil
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["op": "codeStop"], replyHandler: nil, errorHandler: nil)
    }

    // MARK: - The link

    private func ask(_ message: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            DispatchQueue.main.async { [weak self] in
                self?.reachable = false
                self?.problem = "Your phone is not in reach."
            }
            return
        }

        session.sendMessage(message, replyHandler: { reply in
            DispatchQueue.main.async {
                done(reply)
            }
        }, errorHandler: { error in
            DispatchQueue.main.async { [weak self] in
                self?.problem = error.localizedDescription
            }
        })
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.reachable = session.isReachable
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.reachable = session.isReachable
        }
    }

    /// A message the phone received while this was asleep.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            // A pairing finishing is not a message, and the wrist is the only
            // screen the person is looking at when it happens.
            if userInfo["paired"] as? Bool == true {
                self?.paired = true
                self?.loadConversations()
                return
            }

            // Silenced on the phone means silent here. The list is still
            // refreshed: muted is about not being interrupted, not about not
            // being told.
            if userInfo["silent"] as? Bool != true {
                Haptics.arrived()
                Sound.message()
            }
            self?.loadConversations()
        }
    }
}

/// Decode what came across, which arrives as plain dictionaries rather than as
/// anything `WCSession` knows how to type.
private func decode<T: Decodable>(_ type: T.Type, from raw: Any) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
