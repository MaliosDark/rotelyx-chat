import ActivityKit
import SwiftUI
import WidgetKit

/// The flame, breathing.
///
/// # Why a symbol effect and not an animation of ours
///
/// A Live Activity is drawn by the system in a process that is not this one and
/// is redrawn only when the state changes. An animation driven by a timeline of
/// ours would need this to be running, which is the one thing a Live Activity
/// exists to avoid. `symbolEffect` is animated by the system for the life of
/// the activity, so the flame moves on a locked screen with nothing awake.
///
/// A pulse rather than something busier. It sits in the Dynamic Island, a strip
/// the width of a thumbnail that a person glances at while doing something
/// else, and a shape jumping about there is an interruption rather than a
/// signal. Fire breathes; that is the whole of the reference.
///
/// Guarded, because symbol effects arrived in iOS 17 and Live Activities in
/// 16.1. On 16 it is a still flame, which is what it was before.
private struct Flame: View {
    let size: Font

    /// How many are burning. The number rides on the flame when there is more
    /// than one, because the compact island is the only thing most people ever
    /// see: the count was in the expanded view, which nobody opens, so a
    /// single message and five looked identical.
    ///
    /// Nothing at one. A badge reading "1" is a badge that has to be read to
    /// learn there was nothing to learn.
    var count: Int = 1

    var body: some View {
        flame
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        // Off the flame's shoulder rather than over it, so the
                        // shape underneath still reads as fire at a glance.
                        .offset(x: 7, y: -5)
                        .fixedSize()
                }
            }
    }

    @ViewBuilder
    private var flame: some View {
        let mark = Image(systemName: "flame.fill")
            .font(size)
            .foregroundStyle(.orange)

        if #available(iOS 17.0, *) {
            mark.symbolEffect(.pulse, options: .repeating)
        } else {
            mark
        }
    }
}

/// A message destroying itself, on the lock screen and in the Dynamic Island.
///
/// # Why this and not a widget
///
/// A widget has to be added by hand and is redrawn on a schedule the system
/// decides. This appears by itself the moment a message starts counting down,
/// updates every second without being asked, and leaves when the message is
/// gone.
///
/// # Why nobody else has one
///
/// Live Activities are used for deliveries, matches, timers and confirmation
/// codes; Signal uses one for a call in progress. Nothing uses one for a
/// message that expires, and an expiring message is the exact shape Apple
/// designed them for, something with a clear beginning and a clear end.
///
/// It is also the one thing in this application with real urgency. A message
/// you do not read in time is not late, it is gone.
@available(iOS 16.1, *)
struct BurningActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BurnAttributes.self) { context in
            // The lock screen.
            HStack(spacing: 10) {
                Flame(size: .title3, count: context.state.waiting)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.waiting > 1
                        ? "\(context.state.waiting) messages burning"
                        : "A message is burning")
                        .font(.headline)
                    Text("Read it before it goes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(timerInterval: Date.now...context.state.burnsAt,
                     countsDown: true)
                    .font(.system(.title2, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .frame(width: 62)
            }
            .padding()
            .activityBackgroundTint(.black)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Flame(size: .title2, count: context.state.waiting)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date.now...context.state.burnsAt,
                         countsDown: true)
                        .font(.system(.title2, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .frame(width: 62)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.waiting > 1
                        ? "\(context.state.waiting) messages are burning"
                        : "A message is burning")
                        .font(.caption)
                }
            } compactLeading: {
                Flame(size: .body, count: context.state.waiting)
            } compactTrailing: {
                Text(timerInterval: Date.now...context.state.burnsAt,
                     countsDown: true)
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .frame(width: 38)
            } minimal: {
                Flame(size: .body, count: context.state.waiting)
            }
        }
    }
}
