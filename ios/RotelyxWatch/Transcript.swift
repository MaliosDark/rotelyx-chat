import SwiftUI

/// How much room the button takes, so the transcript can leave exactly that
/// much and no more.
private struct ComposerHeight: PreferenceKey {
    static let defaultValue: CGFloat = 60
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Burns what it is applied to, once its moment has come.
///
/// A modifier rather than a branch in the body, so that the fire wraps the
/// capsule alone. Written as an `if` around the whole row, it took the row's
/// size, and the row is as wide as the watch.
private struct BurnWhenDue: ViewModifier {
    let going: Bool
    let onGone: () -> Void

    func body(content: Content) -> some View {
        if going {
            Burning(onGone: onGone) { content }
        } else {
            content
        }
    }
}

/// What is left before a message goes.
///
/// Redrawn once a second by a schedule the system owns rather than by a timer
/// of ours, so a conversation full of expiring messages costs one clock rather
/// than one each, which on a wrist is the difference between a feature and a
/// flat battery.
private struct Countdown: View {
    let to: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let left = Int(max(0, to.timeIntervalSince(tick.date).rounded(.up)))
            Text(left < 60 ? "\(left)" : "\(left / 60):\(String(format: "%02d", left % 60))")
                .font(.system(size: 8, design: .monospaced))
                .monospacedDigit()
        }
    }
}

/// One conversation, and a way to answer it.
struct Transcript: View {
    let conversation: Conversation

    @EnvironmentObject private var phone: Phone

    /// Whether the last message is on screen.
    ///
    /// # Why the button hangs on this and not on scrolling
    ///
    /// A watch screen is small enough that a control parked over it is a line
    /// of the conversation you do not get to read. So it is not always there.
    ///
    /// The first attempt hid it while the transcript moved and brought it back
    /// when it stopped, which needed a timer to decide what "stopped" means and
    /// hid the button from somebody who had simply arrived. Worse, it only ever
    /// worked once: the thing reporting the movement was a row of the `List`,
    /// and scrolling up unmounted it, after which nothing reported anything.
    ///
    /// Being at the end is a state rather than an event, so it cannot get stuck
    /// and needs nothing to be timed. It also says the right thing: reading
    /// back through what somebody said is not the moment to answer, and the
    /// newest message is.
    /// What the button actually measures, rather than what it was guessed to
    /// measure.
    ///
    /// It was a fixed thirty-four points, and the button with its margin is
    /// nearer sixty, so the last two things anybody said sat underneath it. A
    /// number typed here is a number that goes wrong again the moment somebody
    /// turns the text size up, so it is asked for instead.
    ///
    /// Kept while the button is hidden, so the transcript does not jump every
    /// time it comes and goes.
    @State private var composerRoom: CGFloat = 60

    /// The end of the transcript, as somewhere to scroll to.
    private static let foot = "foot"

    /// Whether this transcript has already put itself where it belongs.
    ///
    /// The first landing is instant and every one after it animates. Arriving
    /// at a conversation already in progress is not a movement anybody made,
    /// and watching it slide down from the beginning suggests something
    /// happened; a message arriving while you are reading is an event, and
    /// there the movement is the news.
    @State private var landed = false


    var body: some View {
        GeometryReader { window in
            ZStack(alignment: .bottom) {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 3) {
                            if let problem = phone.problem {
                                Text(problem)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            ForEach(phone.messages) { message in
                                Bubble(message: message)
                                    .id(message.id)
                                    // Arriving from the side it is spoken from,
                                    // so the movement says who is talking
                                    // before the eye has read a word. A message
                                    // that simply exists where nothing was is
                                    // one somebody has to re-read the screen to
                                    // notice.
                                    .transition(.asymmetric(
                                        insertion: .move(
                                            edge: message.mine ? .trailing : .leading)
                                            .combined(with: .opacity),
                                        // Nothing on the way out: leaving is
                                        // what `Burning` is for, and two
                                        // departures playing at once is one
                                        // fighting the other.
                                        removal: .identity))
                            }
                            // `phone.messages` drops the ones that have gone,
                            // which is what takes them off the screen; the
                            // animation above is what makes their leaving
                            // legible rather than a row that was there a moment
                            // ago and is not now.

                            // Two jobs. It is the room the button sits over, so
                            // the last thing said is readable rather than
                            // underneath it, and it is what reports where the
                            // end of the conversation has got to.
                            //
                            // A `ScrollView` over a plain `VStack` rather than a
                            // `List`, because a list builds its rows as they
                            // come into view and drops them as they leave: this
                            // one would stop reporting the moment it scrolled
                            // off, which is precisely when it is needed. The
                            // watch is handed twenty messages at most, so
                            // building all of them costs nothing.
                            Color.clear
                                .frame(height: composerRoom)
                                .id(Transcript.foot)
                        }
                        .padding(.horizontal, 4)
                    }
                    // On arrival as well as on change.
                    //
                    // `onChange` alone only moved when the count moved, so
                    // opening a conversation that already had messages in it
                    // left you at the oldest one, reading upward from a
                    // beginning nobody asked for. Opening a conversation means
                    // wanting the newest thing in it.
                    //
                    // `task(id:)` runs when the view appears and again
                    // whenever the count changes, which is both cases and one
                    // rule.
                    //
                    // Asked more than once, because asking once did not work.
                    // Scrolling to a row that has no position yet does nothing
                    // at all and says nothing about having done nothing, and at
                    // launch a watch is slow enough to lay out that a single
                    // wait of fifty milliseconds landed before the rows
                    // existed. The conversation then opened at its oldest
                    // message, which is the opposite of what anybody opening it
                    // wanted.
                    //
                    // Three widening attempts rather than one long wait: the
                    // usual case is that the first takes and the rest are a
                    // scroll to where it already is, which costs nothing and is
                    // invisible.
                    .animation(.spring(duration: 0.28), value: phone.messages.count)
                    .task(id: phone.messages.count) {
                        for wait in [80, 250, 600] {
                            try? await Task.sleep(for: .milliseconds(wait))
                            guard !Task.isCancelled else { return }

                            // To the foot, which sits below the last message
                            // and is exactly as tall as the button. Landing
                            // here puts the newest thing said and the way to
                            // answer it on screen together, with neither on top
                            // of the other.
                            guard !phone.messages.isEmpty else { return }
                            if landed {
                                withAnimation { scroll.scrollTo(Transcript.foot, anchor: .bottom) }
                            } else {
                                scroll.scrollTo(Transcript.foot, anchor: .bottom)
                            }
                        }
                        landed = true
                    }
                }

                // Always there.
                //
                // It came and went with the scroll for a while, on the argument
                // that a watch screen is too small to park a control on. Three
                // separate bugs came out of that: it hid once and never
                // returned, it appeared over the last message, it stayed away
                // at the end of the conversation, and every one of them was a
                // measurement racing another measurement.
                //
                // The transcript reserves its room instead, so nothing is ever
                // covered, and the way to answer is where it was last time.
                composer
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                    .background(
                        GeometryReader { box in
                            Color.clear.preference(
                                key: ComposerHeight.self,
                                value: box.size.height + 10)
                        })
            }
            .onPreferenceChange(ComposerHeight.self) { composerRoom = $0 }
        }
        // Down into the curve at the bottom of the screen, which the system
        // otherwise keeps clear. The button sits ten points up from the edge
        // rather than the thirty-odd the safe area would have left it, and a
        // capsule that far in is still well clear of the bezel.
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(conversation.title)
        .onAppear { phone.open(conversation) }
    }

    /// The way in, which is a button rather than a field.
    ///
    /// `TextFieldLink` opens watchOS's own input screen, and that screen is
    /// where dictation, scribble, the keyboard and the saved phrases all live
    /// behind one tap. A `TextField` drawn inline offers the same four and
    /// spends a third of a small screen saying so.
    ///
    /// Dictation is in there and this does not advertise it. A microphone was
    /// tried and taken out again: watchOS gives no way to open dictation
    /// directly, so the icon promised a thing it could not do: tapping it
    /// still landed on the chooser, and an icon that names one of four options
    /// and then does not take you to it is worse than one that names none.
    private var composer: some View {
        TextFieldLink(prompt: Text("Message")) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("Reply")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            // Shorter than the default. A control on a watch wants forty-four
            // points to be hittable and the standard button is nearer fifty, so
            // the six that buys nothing go back to the conversation.
            .frame(height: 26)
        } onSubmit: { text in
            send(text)
        }
        .tint(Tone.accent)
        // Its own ground, so the conversation does not show through it. The
        // `.bottomBar` this replaced used a blurred material, and a violet
        // button over a blurred bubble reads as a colour neither of them is.
        .background(Color.black.opacity(0.9), in: Capsule())
    }

    /// One message, in the shape and the colours the phone gives it.
    ///
    /// The violet for what you said and the raised grey for what they said are
    /// the same two colours as `_Bubble` in `lib/ui/screens/chat.dart`, down to
    /// the squared-off corner on the side the bubble is spoken from. A watch is
    /// a second screen onto the same conversation, and a conversation that
    /// looks like a different application on the wrist is one the eye has to
    /// learn twice.
    private struct Bubble: View {
        let message: Message

        @EnvironmentObject private var phone: Phone

        /// Whether this one is on its way out.
        @State private var going = false

        var body: some View {
            bubble.task { await waitForTheDeadline() }
        }

        /// Sleep until the moment the phone named, then burn.
        ///
        /// A task attached to the view rather than a timer somewhere central:
        /// it is cancelled when the message leaves the screen, so nothing is
        /// counting down for a conversation nobody is looking at.
        private func waitForTheDeadline() async {
            guard let left = message.burnsIn else { return }
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            going = true
        }

        private var bubble: some View {
            HStack(spacing: 0) {
                if message.mine { Spacer(minLength: 20) }


                // The flame beside the words, the way the phone marks the same
                // message. Without it a message that destroys itself looked
                // exactly like one that does not, right up until it vanished,
                // and by then knowing is no use.
                HStack(alignment: .top, spacing: 4) {
                    if message.burns {
                        VStack(spacing: 0) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 10))
                            // What is left, ticking, the way the phone counts
                            // it down beside the same flame. A flame alone says
                            // this will go; it does not say whether there is
                            // time to read it, which is the only question
                            // somebody actually has.
                            //
                            // Seconds alone under a minute. `Text(timerInterval:)`
                            // was doing this and always wrote "0:19", which
                            // spends four characters of a very small screen
                            // saying that no minutes remain, and nineteen
                            // seconds is a number, not a time of day.
                            if let deadline = message.deadline {
                                Countdown(to: deadline)
                            }
                        }
                        .foregroundStyle(Tone.fire)
                        .padding(.top, 2)
                    }
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(message.mine ? .white : Tone.text)
                        .multilineTextAlignment(.leading)
                }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(message.mine ? Tone.accent : Tone.raised)
                    .clipShape(.rect(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: message.mine ? 12 : 4,
                        bottomTrailingRadius: message.mine ? 4 : 12,
                        topTrailingRadius: 12))
                    // The fire is given the capsule and nothing else.
                    //
                    // It used to wrap this whole row, which spans the width of
                    // the screen because of the spacer that pushes the capsule
                    // to its side. The field was therefore solved across two
                    // hundred points instead of across the message, and the
                    // tear came out as a line drawn over the conversation with
                    // sparks scattered along it. A fire has to be the size of
                    // the thing that is burning: `lib/ui/burn.dart` learned
                    // the same lesson and says so.
                    .modifier(BurnWhenDue(going: going,
                                          onGone: { phone.forget(message) }))

                if !message.mine { Spacer(minLength: 20) }
            }
        }
    }

    private func send(_ written: String) {
        let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        phone.send(text, to: conversation.id)

        // Asked again rather than appended, so what is on the wrist is what the
        // phone actually holds. A message shown here that the phone refused is
        // worse than one that takes a moment to appear.
        phone.open(conversation)
    }
}
