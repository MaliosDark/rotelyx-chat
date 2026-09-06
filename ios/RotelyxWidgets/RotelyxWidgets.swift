import SwiftUI
import WidgetKit

/// Rotelyx on the home screen and the lock screen.
///
/// # Two widgets, not one with two faces
///
/// A home screen sits behind the passcode; a lock screen is read by whoever the
/// phone is lying in front of. They are different amounts of public, so they
/// are set separately in the application and they read separate rows here.
/// Sharing one setting between them would mean somebody who wanted a name on
/// their home screen accepting it on their lock screen too.
///
/// # What is never here
///
/// Message text, at any size. The rectangular lock screen widget has room for a
/// line of it and does not get one.
@main
struct RotelyxWidgets: WidgetBundle {
    var body: some Widget {
        HomeWidget()
        LockWidget()
        MeetWidget()

        // Live Activities arrived in 16.1 and the application still runs on 15.
        // A phone too old for one shows the other three and never sees a
        // countdown, rather than the whole bundle refusing to build.
        if #available(iOS 16.1, *) {
            BurningActivity()
        }
    }
}

// MARK: - The home screen

struct HomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "rotelyx.home", provider: Provider(surface: "home")) { entry in
            HomeFace(glance: entry.glance).ground()
        }
        .configurationDisplayName("Rotelyx")
        .description("How many conversations are waiting.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct HomeFace: View {
    let glance: Glance

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image("Mark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Rotelyx").font(.headline)
            }

            Spacer(minLength: 0)

            if glance.waiting > 0 {
                Text("\(glance.waiting)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Nothing waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if glance.who.isEmpty { return glance.waiting == 1 ? "conversation" : "conversations" }
        return glance.waiting == 1 ? glance.who : "\(glance.who) +\(glance.waiting - 1)"
    }
}

// MARK: - Meeting somebody

/// Your meeting code, one tap away.
///
/// The most characteristic thing this application does is two people standing
/// in front of each other, one holding up a code. That was four taps from the
/// home screen; this is one.
///
/// It carries nothing. The code is minted when the screen opens, not here — a
/// meeting code lives for one handshake, and one sitting on a home screen for a
/// fortnight would be a meeting anybody who had seen the screen could attend.
struct MeetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "rotelyx.meet", provider: StaticProvider()) { _ in
            MeetFace().ground()
        }
        .configurationDisplayName("Meet someone")
        .description("Show your code to someone standing in front of you.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct MeetFace: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        // `widgetURL` is what the tap opens. `lib/ui/app.dart` reads it and
        // goes straight to the pairing screen with the code already showing.
        Group {
            if family == .accessoryCircular {
                Image(systemName: "qrcode")
                    .font(.title2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                    Text("Show my code")
                        .font(.headline)
                    Text("To meet someone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .widgetURL(URL(string: "rotelyx://meet"))
    }
}

/// A widget with nothing to fetch.
struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, glance: .empty)
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, glance: .empty))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, glance: .empty)], policy: .never))
    }
}

// MARK: - The lock screen

struct LockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "rotelyx.lock", provider: Provider(surface: "lock")) { entry in
            LockFace(glance: entry.glance).ground()
        }
        .configurationDisplayName("Rotelyx")
        .description("How many conversations are waiting. Visible without unlocking.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockFace: View {
    @Environment(\.widgetFamily) private var family
    let glance: Glance

    var body: some View {
        switch family {
        case .accessoryInline:
            // The system owns this row's look — it sits beside the date — so it
            // gets no colour and no font of ours. Fighting it produces a widget
            // that looks broken rather than branded.
            Text(glance.waiting == 0 ? "Rotelyx" : "Rotelyx · \(glance.waiting)")

        case .accessoryRectangular:
            HStack(spacing: 6) {
                mark
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rotelyx").font(.headline)
                    Text(label).font(.caption2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

        default:
            // Circular. The number, or the mark when there is none: a nought in
            // the middle of a lock screen is a thing the eye stops on every
            // time to learn nothing.
            if glance.waiting > 0 {
                Text("\(glance.waiting)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
            } else {
                mark
            }
        }
    }

    private var mark: some View {
        Image("Mark")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var label: String {
        if glance.waiting == 0 { return "Nothing waiting" }
        if glance.who.isEmpty { return "\(glance.waiting) waiting" }
        return glance.waiting == 1 ? glance.who : "\(glance.who) +\(glance.waiting - 1)"
    }
}

/// The background a widget is drawn on.
///
/// `containerBackground` arrived in iOS 17 and is how a widget declares its own
/// ground; before that the system provided one. Guarded rather than required,
/// because the application itself supports iOS 15 and lock screen widgets have
/// worked since 16 — raising the whole extension to 17 would take the feature
/// away from people whose phones can perfectly well show it.
private extension View {
    @ViewBuilder
    func ground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(.fill.tertiary, for: .widget)
        } else {
            self
        }
    }
}

// MARK: - Where the content comes from

struct Entry: TimelineEntry {
    let date: Date
    let glance: Glance
}

/// One entry, never expiring.
///
/// The application reloads the timeline the moment anything changes — see
/// `Widgets.put` — so a schedule here would be the system asking a question
/// whose answer is already sitting in the container, spending battery to learn
/// nothing.
struct Provider: TimelineProvider {
    let surface: String

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, glance: Glance(waiting: 2, who: "Ana"))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, glance: context.isPreview
            ? Glance(waiting: 2, who: "Ana")
            : Glance.read(surface)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, glance: Glance.read(surface))],
                            policy: .never))
    }
}
