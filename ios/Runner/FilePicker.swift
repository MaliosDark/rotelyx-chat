import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Choosing a file, through the system picker and nothing else.
///
/// The same shape as `android/.../FilePicker.kt` and for the same reason: this
/// asks for **no permission at all**. `UIDocumentPickerViewController` is drawn
/// by the system, the person picks one file, and this process is handed that
/// one file.
///
/// Pictures go through `PHPickerViewController`, which asks for nothing either.
/// It was avoided here on the belief that it cost
/// `NSPhotoLibraryUsageDescription`, and that has not been true since iOS 14:
/// the grid is drawn by a separate process that this application cannot see
/// into, and what comes back is the one picture that was tapped. There is no
/// permission, no prompt, and nothing on the privacy screen.
///
/// Which is why sending a photograph now opens the photographs rather than the
/// file system. Somebody attaching a picture was being shown a list of folders
/// and having to go and find it, which is the wrong question asked politely.
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

        let args = call.arguments as? [String: Any]
        limit = args?["maxBytes"] as? Int ?? FilePicker.defaultMax
        pending = result

        if args?["images"] as? Bool == true, #available(iOS 14.0, *) {
            presentPhotos()
            return
        }

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

    /// The system photograph grid.
    ///
    /// Out of process, so this application never sees the library, only the one
    /// picture that was chosen. Nothing is asked of the person and nothing
    /// appears on the privacy screen.
    @available(iOS 14.0, *)
    private func presentPhotos() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self

        guard let host = host else {
            let waiting = pending
            pending = nil
            waiting?(FlutterError(code: "nopicker",
                                  message: "no window to present from", details: nil))
            return
        }
        host.present(picker, animated: true)
    }

    func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "pick": pick(call, result)
        default: result(FlutterMethodNotImplemented)
        }
    }
}

@available(iOS 14.0, *)
extension FilePicker: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController,
                didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let waiting = pending else { return }
        pending = nil

        // Backed out. Null rather than an error, as with the other picker.
        guard let item = results.first?.itemProvider else {
            waiting(nil)
            return
        }

        // Asked for by type rather than as an image.
        //
        // `loadObject(ofClass: UIImage.self)` hands back a decoded bitmap, and
        // re-encoding it here would throw away whatever the camera wrote and
        // replace it with something larger. The bytes on disk are what is
        // wanted, and the size check below is about those bytes rather than
        // about a picture this process happened to redraw.
        let wanted = [UTType.jpeg, UTType.png, UTType.heic, UTType.gif]
        let type = wanted.first { item.hasItemConformingToTypeIdentifier($0.identifier) }
            ?? UTType.image

        item.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            DispatchQueue.main.async {
                guard let data = data else {
                    waiting(FlutterError(
                        code: "unreadable",
                        message: error?.localizedDescription ?? "that picture could not be read",
                        details: nil))
                    return
                }

                if data.count > self.limit {
                    waiting(FlutterError(
                        code: "toolarge",
                        message: "that picture is \(data.count / 1024 / 1024) MB, "
                            + "and the limit is \(self.limit / 1024 / 1024) MB",
                        details: nil))
                    return
                }

                let name = item.suggestedName ?? "picture"
                let extension_ = type.preferredFilenameExtension ?? "jpg"

                waiting([
                    "name": name.contains(".") ? name : "\(name).\(extension_)",
                    "mime": type.preferredMIMEType ?? "image/jpeg",
                    "bytes": FlutterStandardTypedData(bytes: data),
                ])
            }
        }
    }
}
