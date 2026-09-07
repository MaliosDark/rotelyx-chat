import Flutter
import Photos
import UIKit

/// Keeping a copy of a picture somebody was sent.
///
/// # The permission, and why it is the narrow one
///
/// This asks for `NSPhotoLibraryAddUsageDescription` and never
/// `NSPhotoLibraryUsageDescription`. The two are a sentence apart on the
/// permission screen and a world apart in what they grant:
///
///   * **Add only**, which is this. The application may put a picture into the
///     library. It cannot list what is there, cannot open anything, and cannot
///     tell whether the picture it just saved is the only one on the device or
///     one of forty thousand. iOS grants it with a single prompt and there is
///     nothing further to review, because there is nothing further to give.
///   * **Full access**, which this refuses. The application may read the whole
///     library at any time it is running.
///
/// Choosing a picture to send does not use either one. That goes through
/// `PHPickerViewController`, which runs outside this process and hands back the
/// one photograph that was tapped, and it asks for nothing at all. See
/// `FilePicker.swift`.
///
/// So the only moment this application ever touches the photo library is the
/// moment somebody presses save on a picture they were sent and want to keep.
/// That is the whole of it, and it is what the description in `Info.plist`
/// says.
///
/// # Why saving is offered at all
///
/// A message that self destructs is a promise this application keeps. A
/// photograph a friend sent and meant you to have is not that, and an
/// application that will not let somebody keep a picture of their own child is
/// not being private, it is being difficult. The two are separated where they
/// belong: a picture set to burn is gone and cannot be saved, and one that is
/// not is theirs.
class SaveToPhotos: NSObject {

    static let channel = "rotelyx/photos"

    /// Write to the library, asking the first time.
    ///
    /// `addOnly` is passed explicitly. Asking for `.readWrite` here would
    /// produce the prompt this file exists to avoid, and iOS would remember the
    /// answer.
    private func save(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = (args["bytes"] as? FlutterStandardTypedData)?.data
        else {
            result(FlutterError(code: "nodata", message: "no picture to save", details: nil))
            return
        }

        // Decoded here rather than written as a file.
        //
        // What arrives is this application's own codec, which the system has
        // never heard of, so `PHAssetCreationRequest` with the raw bytes would
        // store something the Photos application cannot open. Dart hands over
        // pixels and this makes a PNG of them, which every part of the system
        // understands.
        guard let width = args["width"] as? Int,
              let height = args["height"] as? Int,
              let image = SaveToPhotos.image(from: data, width: width, height: height)
        else {
            result(FlutterError(code: "undecodable",
                                message: "that picture could not be prepared",
                                details: nil))
            return
        }

        let write = {
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { done, error in
                DispatchQueue.main.async {
                    if done {
                        result(nil)
                    } else {
                        result(FlutterError(code: "failed",
                                            message: error?.localizedDescription
                                                ?? "the picture could not be saved",
                                            details: nil))
                    }
                }
            }
        }

        if #available(iOS 14.0, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited:
                write()
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
                    DispatchQueue.main.async {
                        switch granted {
                        case .authorized, .limited:
                            write()
                        default:
                            result(FlutterError(code: "refused",
                                                message: "saving pictures is switched off for Rotelyx",
                                                details: nil))
                        }
                    }
                }
            default:
                result(FlutterError(code: "refused",
                                    message: "saving pictures is switched off for Rotelyx",
                                    details: nil))
            }
        } else {
            write()
        }
    }

    /// Build a `UIImage` from the pixels Dart decoded.
    private static func image(from rgba: Data, width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }

        var bytes = [UInt8](rgba)
        let space = CGColorSpaceCreateDeviceRGB()
        let info: CGBitmapInfo = [.byteOrder32Big,
                                  CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]

        guard let context = CGContext(data: &bytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: info.rawValue),
              let cg = context.makeImage()
        else { return nil }

        return UIImage(cgImage: cg)
    }

    func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "save": save(call, result)
        default: result(FlutterMethodNotImplemented)
        }
    }
}
