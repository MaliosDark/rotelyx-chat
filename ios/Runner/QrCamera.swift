import AVFoundation
import Flutter

/// The back camera, as a stream of grey frames Dart reads a QR code out of.
///
/// The same contract as `android/.../QrCamera.kt`: a width, a height, and one
/// byte of brightness per pixel. The decoder is in `lib/qr/` and is not
/// reimplemented here.
///
/// # Why not `AVCaptureMetadataOutput`
///
/// iOS will read a QR code for you in three lines. It is not used, for the same
/// reason the browser build does not fetch a decoder from a CDN: the decoder in
/// `lib/qr/` is tested against every version and correction level, against
/// damage up to the correction budget, and against a photograph taken at an
/// angle in poor light. Two decoders means the one that ships on one platform
/// is the one nobody tested.
///
/// This produces frames. That is all.
///
/// # The row padding trap, which is the same on both platforms
///
/// `CVPixelBuffer` pads each row out to a convenient width, and the padding is
/// not image data. Copying the plane straight out shears the picture
/// diagonally. It still looks like a photograph and it never decodes.
class QrCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    static let channel = "rotelyx/camera"

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "rotelyx-camera")
    private var registry: FlutterTextureRegistry?
    private var textureId: Int64 = 0

    /// The most recent frame, replaced as they arrive and read when asked for.
    private var latest: (bytes: Data, width: Int, height: Int)?
    private let lock = NSLock()

    /// The pixel buffer the texture is drawn from.
    private var displayed: CVPixelBuffer?

    init(registry: FlutterTextureRegistry?) {
        self.registry = registry
    }

    private func start(_ result: @escaping FlutterResult) {
        guard session.isRunning == false else {
            result(FlutterError(code: "already", message: "the camera is already open", details: nil))
            return
        }

        session.beginConfiguration()
        // Not the highest available. A QR code fills a good part of the frame
        // and its modules are large; a five megapixel frame gives the decoder
        // the same grid with twenty times the bytes to copy.
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            result(FlutterError(code: "camera", message: "the camera would not open", details: nil))
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        // Drop what cannot be kept up with. A code that was in front of the
        // camera four frames ago is not useful, and a backlog turns a slow
        // decode into a frozen preview.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            result(FlutterError(code: "camera", message: "the camera would not deliver frames", details: nil))
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        textureId = registry?.register(self) ?? 0
        queue.async { self.session.startRunning() }

        result(["texture": textureId, "width": 1280, "height": 720])
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }

        // The brightness plane with the row padding removed. Ignoring the
        // stride shears the picture; see the class comment.
        var luma = Data(count: width * height)
        luma.withUnsafeMutableBytes { destination in
            guard let out = destination.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<height {
                memcpy(out + row * width, base + row * stride, width)
            }
        }

        lock.lock()
        latest = (luma, width, height)
        displayed = pixels
        lock.unlock()

        registry?.textureFrameAvailable(textureId)
    }

    /// Hand Dart the newest frame, or nothing if none has arrived yet.
    private func frame(_ result: @escaping FlutterResult) {
        lock.lock()
        let held = latest
        lock.unlock()

        guard let held = held else {
            result(nil)
            return
        }
        result([
            "bytes": FlutterStandardTypedData(bytes: held.bytes),
            "width": held.width,
            "height": held.height,
        ])
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        if textureId != 0 { registry?.unregisterTexture(textureId) }
        textureId = 0

        lock.lock()
        latest = nil
        displayed = nil
        lock.unlock()
    }

    func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "permit":
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { result(granted) }
            }
        case "start": start(result)
        case "frame": frame(result)
        case "stop":
            stop()
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }
}

extension QrCamera: FlutterTexture {
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        let buffer = displayed
        lock.unlock()
        guard let buffer = buffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }
}
