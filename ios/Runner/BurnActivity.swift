import ActivityKit
import Flutter
import Foundation

/// The Live Activity that counts a burning message down.
///
/// # What travels, and what deliberately does not
///
/// A deadline and a count. Not who it is from, not a word of what it says, not
/// which conversation it belongs to. This is drawn on a locked screen and in
/// the Dynamic Island, which is the most public surface an iPhone has, and the
/// only thing that surface needs to know is how long is left.
///
/// It is also, unusually, more private than the notification that preceded it:
/// a notification carries a name and often the message, and this carries a
/// number that counts down.
///
/// # Why the system moves the number and not us
///
/// The activity is handed a date, and `Text(timerInterval:)` in the extension
/// counts towards it. So the countdown ticks on a locked phone without this
/// process waking once a second to move it — which on a battery is the
/// difference between a feature and a complaint.
@available(iOS 16.2, *)
enum BurnActivity {

    private static var live: Activity<BurnAttributes>?

    /// Start, or move the one already running.
    ///
    /// One activity, not one per message. Two flames in the Dynamic Island is
    /// two things competing for a space the width of a thumbnail; the count
    /// says there are several and the deadline is the soonest of them.
    static func show(burnsAt: Date, waiting: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = BurnAttributes.ContentState(burnsAt: burnsAt, waiting: waiting)

        if let live = live {
            Task {
                // Ends itself at the deadline even if this application never
                // runs again. A countdown left on a lock screen after the thing
                // it counted is gone is worse than no countdown.
                await live.update(ActivityContent(state: state, staleDate: burnsAt))
            }
            return
        }

        live = try? Activity.request(
            attributes: BurnAttributes(),
            content: ActivityContent(state: state, staleDate: burnsAt),
            pushType: nil)
    }

    /// Nothing is counting any more.
    static func hide() {
        guard let activity = live else { return }
        live = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

/// The channel the application speaks to it through.
enum BurnActivityChannel {
    static let name = "rotelyx/burn"

    static func start(_ messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: name, binaryMessenger: messenger)
            .setMethodCallHandler { call, result in
                guard #available(iOS 16.2, *) else {
                    result(nil)
                    return
                }

                switch call.method {
                case "show":
                    guard let args = call.arguments as? [String: Any],
                          let at = args["burnsAt"] as? Double
                    else {
                        result(nil)
                        return
                    }
                    BurnActivity.show(
                        burnsAt: Date(timeIntervalSince1970: at / 1000),
                        waiting: args["waiting"] as? Int ?? 1)
                case "hide":
                    BurnActivity.hide()
                default:
                    result(FlutterMethodNotImplemented)
                    return
                }
                result(nil)
            }
    }
}
