import SwiftUI
import WatchKit

/// A meeting code, on the wrist, for somebody standing in front of you.
///
/// # Why a watch may show this when it may not show a key
///
/// A meeting code is public. It is 120 random bits naming a place to meet for
/// the length of one handshake; it authenticates nobody, and the safety number
/// on the phone is still the only check that matters. Showing one gives away
/// nothing that was not about to be pointed at a stranger's camera anyway.
///
/// Everything underneath it happens on the phone. The phone mints the code,
/// waits at the place it names, does the handshake and keeps the conversation.
/// This is a surface to point a camera at, which is the whole of what a watch
/// is for here. Turn the wrist away and the phone is still the only thing
/// holding a key — the same bargain as the rest of this application.
///
/// # Why the squares arrive rather than the string
///
/// The phone encodes the symbol with the same library, version and error
/// correction the pairing screen uses, and sends the rows. Encoding it again
/// here would be a second encoder, differing in some detail, producing a code
/// that reads off one screen and not the other. See `lib/rotelyx/qr_matrix.dart`.
struct MyCode: View {
    @EnvironmentObject private var phone: Phone
    @Environment(\.dismiss) private var dismiss

    /// A store screenshot, and nothing else.
    ///
    /// A watch cannot be tapped from a script and the real symbol only exists
    /// after the phone has minted one and reached a mailbox, so a picture of
    /// this screen would otherwise need a person and a working network. This is
    /// one real symbol for one dead meeting code, produced by the encoder in
    /// `lib/rotelyx/qr_matrix.dart` — the same rows the phone would have sent.
    ///
    /// `#if DEBUG`, so no released build carries it or the flag that shows it.
    #if DEBUG
    private static let fixture = [
        "111111100110011101001100001111111",
        "100000100010101000110001101000001",
        "101110100011010000110010001011101",
        "101110100100110100110110101011101",
        "101110101110011011101011101011101",
        "100000100011101100111101001000001",
        "111111101010101010101010101111111",
        "000000001001001001111010100000000",
        "001100111011000000110111111010000",
        "000101010010100000101110010000011",
        "001110110100110110110001001000001",
        "001101010001011000010000100101001",
        "001110110011110010000100000101101",
        "000111011010001101000111110001111",
        "110100100100101110111110010111000",
        "000101010101101000011100111001110",
        "001011100101101100000100011110010",
        "010100001110011000100000110010000",
        "011000100001100111110110011110010",
        "011001000101111100000001000010001",
        "101001110101001000101000101111011",
        "110110011101100110011100100000111",
        "000111101010001010001111100101101",
        "011110011111101001111010010101011",
        "100000101100000001011110111110100",
        "000000001001101011100101100010001",
        "111111101011010111011100101010100",
        "100000100010010011110001100011111",
        "101110100101100011111011111110011",
        "101110101100111100000110110010000",
        "101110101001110111111011011001000",
        "100000100111110010011000011000001",
        "111111100000110010011011010110000",
    ]

    private var fixtureRows: [String]? {
        ProcessInfo.processInfo.arguments.contains("-showCode") ? MyCode.fixture : nil
    }
    #endif

    /// The code in words that goes with the fixture symbol above.
    private var screenshotCode: String? {
        #if DEBUG
        return fixtureRows == nil ? nil : "RTLX1 AJ7K 2MQ4 XPTB 9VZ3 NDW6 HYSE"
        #else
        return nil
        #endif
    }

    /// What to draw: whatever the phone sent, or the fixture when a screenshot
    /// is being taken and no phone answered.
    private func rows(_ sent: [String]?) -> [String]? {
        #if DEBUG
        return sent ?? fixtureRows
        #else
        return sent
        #endif
    }

    var body: some View {
        // Sized to the screen rather than scrolled. A code you have to scroll
        // to is a code somebody fumbles for while another person waits, which
        // is exactly the moment this screen exists for.
        GeometryReader { screen in
            VStack(spacing: 4) {
                if let rows = rows(phone.codeRows) {
                    QrPlate(rows: rows)
                        .frame(
                            width: min(screen.size.width, screen.size.height - 30),
                            height: min(screen.size.width, screen.size.height - 30))

                    Text("Have them scan this")
                        .font(.system(size: 11))
                        .foregroundStyle(Tone.muted)

                    // The same code in words, for a camera that will not
                    // cooperate and a person willing to type. One line: it is
                    // the fallback, and giving it two would cost the symbol
                    // above it the room that makes it readable.
                    if let code = phone.code ?? screenshotCode {
                        Text(code)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Tone.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                } else if let problem = phone.problem {
                    Spacer()
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    Spacer()
                    ProgressView()
                    Text("Asking your phone for a code")
                        .font(.system(size: 11))
                        .foregroundStyle(Tone.muted)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Your code")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { phone.showCode() }
        // Stop waiting when the wrist drops. The pairing itself is left alone:
        // a scan already in flight is not this screen's to cancel.
        .onDisappear { phone.stopCode() }
        // Somebody scanned it. Say so on the wrist, because the phone is in a
        // pocket and this screen is the only thing the person is looking at.
        .onChange(of: phone.paired) {
            guard phone.paired else { return }
            Haptics.paired()
            dismiss()
        }
    }
}

/// The symbol on its white field, with the Rotelyx mark set into the middle.
///
/// The mark is not decoration and it is not free either: it covers modules.
/// `logoShare` on the phone is 0.24 of the width, chosen against error
/// correction H, and it is the same fraction here — a symbol that looks like
/// the phone's but eats more of itself is one that scans on a desk and fails
/// in a doorway. The white ring around the mark separates it from the modules
/// beside it so a scanner reads a boundary rather than a smear.
private struct QrPlate: View {
    let rows: [String]

    /// How much of the symbol's width the mark takes. The same number as
    /// `logoShare` in `lib/ui/brand.dart`, which `test/meeting_code_test.dart`
    /// asserts against.
    private static let logoShare = 0.24

    var body: some View {
        GeometryReader { box in
            let side = min(box.size.width, box.size.height)
            // The quiet zone. A QR with content pressed against its edge is
            // markedly harder to find, and the standard asks for four modules
            // of margin for exactly this reason.
            let quiet = (side * 0.05).rounded()
            let plate = side * QrPlate.logoShare

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white)

                QrSquares(rows: rows)
                    .frame(width: side - quiet * 2, height: side - quiet * 2)

                RoundedRectangle(cornerRadius: plate * 0.24)
                    .fill(.white)
                    .frame(width: plate, height: plate)

                Image("Mark")
                    .resizable()
                    .scaledToFill()
                    .frame(width: plate * 0.84, height: plate * 0.84)
                    .clipShape(RoundedRectangle(cornerRadius: plate * 0.18))
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The symbol, drawn as the squares the phone said it was made of.
///
/// One `Path` for every dark module rather than one rectangle per draw call:
/// a version 4 symbol is 33 across, so this is a thousand small squares and a
/// watch redraws it whenever the wrist turns.
private struct QrSquares: View {
    let rows: [String]

    var body: some View {
        Canvas { context, size in
            let count = rows.count
            guard count > 0 else { return }

            // Floor rather than divide, and draw on whole pixels: a module
            // boundary landing mid-pixel is a blurred edge, and a blurred edge
            // is a symbol a camera hunts for instead of reading.
            let module = (size.width / CGFloat(count)).rounded(.down)
            guard module >= 1 else { return }

            let inset = ((size.width - module * CGFloat(count)) / 2).rounded()
            var dark = Path()

            for (y, row) in rows.enumerated() {
                for (x, unit) in row.utf8.enumerated() where unit == 0x31 {
                    dark.addRect(CGRect(
                        x: inset + CGFloat(x) * module,
                        y: inset + CGFloat(y) * module,
                        width: module,
                        height: module))
                }
            }

            context.fill(dark, with: .color(.black))
        }
    }
}
