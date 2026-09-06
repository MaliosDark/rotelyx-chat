import Flutter
import Foundation
import WidgetKit

/// What the widgets are allowed to say, and where it is kept.
///
/// # Why anything is written down
///
/// A widget is drawn by a separate process on a schedule the system owns, long
/// after the application last ran. It cannot ask this one anything. So what it
/// shows has to be sitting in the shared container before it is needed.
///
/// The same bargain as `ios/RotelyxWatch/Glance.swift`, and the same limit: a
/// number and at most a name. No message text on any surface, at any size.
///
/// # Why the filtering is not here
///
/// `lib/platform/widgets_native.dart` decides what may travel, and what is
/// refused is never written rather than written and hidden. A widget reading
/// this container can only draw what is in it, so a setting enforced at the
/// other end is a setting the widget cannot get wrong.
enum Widgets {

    static let channel = "rotelyx/widgets"
    static let group = "group.com.rotelyx.ios"

    private static var store: UserDefaults? { UserDefaults(suiteName: group) }

    static func start(_ messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: channel, binaryMessenger: messenger)
            .setMethodCallHandler { call, result in
                guard call.method == "put",
                      let args = call.arguments as? [String: Any]
                else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                put(args)
                result(nil)
            }
    }

    /// Write what the widgets may show, and tell them to redraw.
    ///
    /// Reloading is not optional: a widget is not asked for its timeline
    /// because something changed, only because it said when to ask. Left out,
    /// the home screen keeps yesterday's number until the system next feels
    /// like it.
    private static func put(_ what: [String: Any]) {
        guard let store = store else { return }
        store.set(what["homeWaiting"] as? Int ?? 0, forKey: "home.waiting")
        store.set(what["homeWho"] as? String ?? "", forKey: "home.who")
        store.set(what["lockWaiting"] as? Int ?? 0, forKey: "lock.waiting")
        store.set(what["lockWho"] as? String ?? "", forKey: "lock.who")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
