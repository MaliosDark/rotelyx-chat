import Flutter
import UIKit
import UniformTypeIdentifiers

/// Choosing a file, through the system picker and nothing else.
///
/// The same shape as `android/.../FilePicker.kt` and for the same reason: this
/// asks for **no permission at all**. `UIDocumentPickerViewController` is drawn
/// by the system, the person picks one file, and this process is handed that
/// one file.
///
/// The alternative, `PHPickerViewController` against the photo library, gives a
/// prettier grid and costs `NSPhotoLibraryUsageDescription` on the permission
/// screen, which a person reads as "this application can see all my
/// photographs". For an application whose argument is that it holds nothing,
/// the plainer picker is the honest one.
///
/// # Why the bytes are copied here
///
/// A URL from the picker is security-scoped and valid inside
/// `startAccessingSecurityScopedResource`. Handing it to Dart to open later
/// produces a permission failure at whatever moment the person finally presses
/// send, which is the worst place to discover it.
class FilePicker: NSObject, UIDocumentPickerDelegate {

    static let channel = "rotelyx/files"

    /// Refused before it is read, so a huge file is not copied into memory in
    /// order to be rejected afterwards.
    private static let defaultMax = 16 * 1024 * 1024

    private var pending: FlutterResult?
    private var limit = FilePicker.defaultMax
    private weak var host: UIViewController?

    init(host: UIViewController?) {
        self.host = host
    }

    private func pick(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if pending != nil {
            result(FlutterError(code: "busy", message: "a picker is already open", details: nil))
            return
        }

        limit = (call.arguments as? [String: Any])?["maxBytes"] as? Int
            ?? FilePicker.defaultMax
        pending = result

        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.item"],
                                                    in: .import)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false

        guard let host = host else {
            pending = nil
            result(FlutterError(code: "nopicker", message: "no window to present from", details: nil))
            return
        }
        host.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let waiting = pending else { return }
        pending = nil

        guard let url = urls.first else {
            result(waiting, nil)
            return
        }

        // Security scoped, and released whatever happens below.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int, size > limit {
                waiting(FlutterError(code: "toolarge",
                                     message: "that file is \(size / 1024 / 1024) MB, and the limit is \(limit / 1024 / 1024) MB",
                                     details: nil))
                return
            }

            let data = try Data(contentsOf: url)
            if data.count > limit {
                waiting(FlutterError(code: "toolarge",
                                     message: "that file is larger than \(limit / 1024 / 1024) MB",
                                     details: nil))
                return
            }

            waiting([
                "name": url.lastPathComponent,
                "mime": mime(for: url),
                "bytes": FlutterStandardTypedData(bytes: data),
            ])
        } catch {
            waiting(FlutterError(code: "unreadable",
                                 message: error.localizedDescription,
                                 details: nil))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Backed out. Null rather than an error: choosing nothing is a thing
        // people do and should not produce a message.
        let waiting = pending
        pending = nil
        waiting?(nil)
    }

    private func result(_ waiting: FlutterResult, _ value: Any?) {
        waiting(value)
    }

    private func mime(for url: URL) -> String {
        if #available(iOS 14.0, *),
           let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "pick": pick(call, result)
        default: result(FlutterMethodNotImplemented)
        }
    }
}
