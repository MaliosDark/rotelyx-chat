import SwiftUI

/// The conversations, most recent first.
struct ConversationList: View {
    @EnvironmentObject private var phone: Phone

    /// Screenshot fixture, compiled out of anything but a debug build.
    ///
    /// The same idea as `--dart-define=screen=` on the phone: a watch cannot be
    /// tapped from a script, so a store screenshot of a transcript needs the
    /// application to open one by itself. `#if DEBUG` rather than a launch
    /// argument, so no released build carries a way to skip to a conversation.
    @State private var showingFirst = false

    /// The other screenshot fixture, and the same bargain: the store wants a
    /// picture of the code screen, and a watch cannot be tapped from a script.
    @State private var showingCode = false

    /// Opened when the conversations arrive rather than after a guessed wait:
    /// they come from the phone over a link that takes as long as it takes.
    private func openFirstForAScreenshot() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-openFirst") else { return }
        guard !showingFirst, !phone.conversations.isEmpty else { return }
        showingFirst = true
        #endif
    }

    var body: some View {
        List {
            // First rather than last. Meeting somebody is the thing a person
            // does with a phone in a pocket, which is the only reason to reach
            // for the watch instead of the phone at all.
            NavigationLink {
                MyCode()
            } label: {
                Label("Show my code", systemImage: "qrcode")
                    .font(.footnote)
            }

            if !phone.reachable {
                Text("Your phone is not in reach")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(phone.conversations) { conversation in
                NavigationLink {
                    Transcript(conversation: conversation)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title)
                            .font(.headline)
                        // The last thing said, on one line. A watch shows a
                        // handful of them and a wrapped preview costs the row
                        // below it.
                        Text(conversation.last)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if phone.conversations.isEmpty && phone.reachable {
                Text("No conversations")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Rotelyx")
        .onAppear {
            phone.loadConversations()
            // Also here, not only on the change below: conversations that were
            // already there when this appeared never change count, and the
            // fixture would sit waiting for an event that had happened before
            // there was anything to notice it.
            openFirstForAScreenshot()
            #if DEBUG
            showingCode = ProcessInfo.processInfo.arguments.contains("-showCode")
            #endif
        }
        .onChange(of: phone.conversations.count) { _ in openFirstForAScreenshot() }
        // Hidden links rather than `navigationDestination`, which is watchOS 9.
        .background(
            Group {
                NavigationLink(isActive: $showingFirst) {
                    if let first = phone.conversations.first {
                        Transcript(conversation: first)
                    }
                } label: { EmptyView() }

                NavigationLink(isActive: $showingCode) { MyCode() } label: { EmptyView() }
            }
            .hidden()
        )
    }
}
