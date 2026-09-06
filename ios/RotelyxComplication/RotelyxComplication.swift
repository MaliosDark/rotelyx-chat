import SwiftUI
import WidgetKit

/// Rotelyx on the watch face.
///
/// # Why this is a complication and not a face
///
/// watchOS has no third-party watch faces and never has: no application can
/// draw one, and there is no API to ask for. What an application may do is put
/// itself on Apple's faces, which is what this is. A face with the Rotelyx mark
/// on it is a face somebody configured, not a face somebody wrote.
///
/// # Why it says a number and a name and no more
///
/// A complication is read by whoever is standing next to the wrist. It is on
/// screen with no unlock, no passphrase and no intent — a face is a thing other
/// people look at. So there is no message text here at any size, including the
/// rectangular one that has room for it. `Glance` holds what is shown and
/// nothing else is available to hold.
@main
struct RotelyxComplication: WidgetBundle {
    var body: some Widget {
        Waiting()
    }
}

struct Waiting: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "rotelyx.waiting", provider: Provider()) { entry in
            Face(glance: entry.glance)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Rotelyx")
        .description("How many conversations are waiting.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular,
        ])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let glance: Glance
}

/// Where the face's content comes from.
///
/// One entry, never expiring. The watch application reloads the timeline the
/// moment anything changes — see `Glance.write` — so a schedule here would be
/// the system asking a question whose answer is already sitting in the
/// container, spending battery to learn nothing.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, glance: Glance(waiting: 2, who: "Ana"))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, glance: context.isPreview
            ? Glance(waiting: 2, who: "Ana")
            : Glance.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, glance: Glance.read())],
                            policy: .never))
    }
}

/// The same fact drawn four ways, because a face has four shapes of hole.
struct Face: View {
    @Environment(\.widgetFamily) private var family
    let glance: Glance

    var body: some View {
        switch family {
        case .accessoryInline:
            // One line of the system's own text, beside the date. It gets no
            // colour and no font: the system owns this row's look, and fighting
            // it produces a complication that looks broken rather than branded.
            Text(glance.waiting == 0 ? "Rotelyx" : "Rotelyx · \(glance.waiting)")

        case .accessoryCorner:
            mark
                .widgetLabel { Text(label) }

        case .accessoryRectangular:
            HStack(spacing: 6) {
                mark
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rotelyx")
                        .font(.headline)
                    // A name, not a message. See the note on `Glance`.
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

        default:
            // Circular. The number, or the mark when there is no number: a
            // nought drawn in the middle of a face is a thing the eye stops on
            // every time to learn nothing.
            if glance.waiting > 0 {
                Text("\(glance.waiting)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
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

    /// What the wider shapes say under the mark.
    private var label: String {
        if glance.waiting == 0 { return "Nothing waiting" }
        if glance.who.isEmpty { return "\(glance.waiting) waiting" }
        return glance.waiting == 1 ? glance.who : "\(glance.who) +\(glance.waiting - 1)"
    }
}
