import Flutter
import UIKit
import UniformTypeIdentifiers

/// Reading a picture somebody copied, and nothing else.
///
/// # Why this exists rather than a sticker browser
///
/// There is no API for the stickers on an iPhone. Memoji, the packs that come
/// with an application, and whatever GIF keyboard somebody installed are the
/// keyboard's business, and the keyboard hands them to a text field as rich
/// content. A Flutter text field is plain text and drops them, and Flutter's
/// own hook for keyboard content is Android only.
///
/// What is left is the route every one of those keyboards already supports:
/// the person copies, and this pastes. No third party is called, nothing is
/// searched, and the only thing this application ever sees is the one picture
/// somebody chose to put on the clipboard.
///
/// # Why asking and reading are two calls
///
/// Reading the clipboard raises the banner iOS shows when an application
/// looks: "Rotelyx pasted from Photos". Asking whether there is an image does
/// not, because `hasImages` is answered without handing the contents over.
///
/// So the offer is made from the cheap question and the bytes are taken only
/// once somebody has tapped it. Nobody is told this application went looking
/// through their clipboard, because it did not.
class Clipboard: NSObject {

    static let channel = "rotelyx/clipboard"

    /// Whether there is a picture to offer. Costs nothing and tells nobody.
    private func has(_ result: @escaping FlutterResult) {
        result(UIPasteboard.general.hasImages)
    }

    /// The picture itself, in the format it was copied in where that matters.
    ///
    /// An animation is asked for first and by type. `UIPasteboard.image`
    /// decodes to a `UIImage`, which is one frame, so a GIF copied from a
    /// keyboard would arrive as a still through exactly the fault the picture
    /// path had. The raw bytes keep it moving.
    private func read(_ result: @escaping FlutterResult) {
        let board = UIPasteboard.general

        let wanted: [(UTType, String)] = [
            (.gif, "image/gif"),
            (.png, "image/png"),
            (.jpeg, "image/jpeg"),
        ]

        for (type, mime) in wanted {
            if let data = board.data(forPasteboardType: type.identifier) {
                result(["bytes": FlutterStandardTypedData(bytes: data), "mime": mime])
                return
            }
        }

        // Anything else the system can turn into a picture, as PNG so that
        // what arrives is a format every platform draws.
        if let image = board.image, let png = image.pngData() {
            result(["bytes": FlutterStandardTypedData(bytes: png), "mime": "image/png"])
            return
        }

        result(nil)
    }

    func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "has": has(result)
        case "read": read(result)
        default: result(FlutterMethodNotImplemented)
        }
    }
}
