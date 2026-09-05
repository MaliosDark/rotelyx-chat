import AVFoundation
import Flutter

/// The microphone and the speaker, in twenty millisecond frames.
///
/// The same contract as `android/.../CallAudio.kt`, deliberately: 960 signed
/// sixteen bit samples, mono, at 48 kHz. The codec was built around that window
/// and does not negotiate, so both platforms produce exactly it and the Dart
/// above them cannot tell which one it is talking to.
///
/// # Why `AVAudioEngine` and not `AudioUnit`
///
/// A raw audio unit gives more control over latency and costs several hundred
/// lines of C to get right. `AVAudioEngine` with a tap is the same job in forty,
/// and the extra control buys nothing here because the frame size is fixed by
/// the codec rather than by what the device would prefer.
///
/// # The session category is the whole of the call routing
///
/// `.playAndRecord` with `.voiceChat` is what puts iOS into call mode: it turns
/// on the platform's echo cancellation, routes to the earpiece rather than the
/// speaker, ducks other audio, and keeps the call alive when the screen locks.
/// Setting it wrong does not fail, it produces a call that sounds like a
/// speakerphone in a bathroom.
class CallAudio {

    static let channel = "rotelyx/call-audio"

    /// Samples in one frame. Twenty milliseconds at `rate`.
    static let frame = 960
    static let rate: Double = 48000

    /// How many captured frames may wait before the oldest is dropped.
    ///
    /// Past two hundred milliseconds a frame is not worth sending: the person
    /// it belongs to has moved on, and delivering it late makes the call sound
    /// further behind rather than more complete.
    private static let backlog = 10

    private let engine = AVAudioEngine()
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?

    private var ready: [Data] = []
    private let lock = NSLock()
    private var dropped = 0
    private var running = false

    func start(_ result: @escaping FlutterResult) {
        if running {
            result(true)
            return
        }

        let session = AVAudioSession.sharedInstance()

        do {
            // `.voiceChat` is the line that matters. It is what turns on echo
            // cancellation and routes to the earpiece; without it a call sounds
            // like a speakerphone in a bathroom, and nothing reports an error.
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.allowBluetooth])
            try session.setActive(true)
        } catch let error as NSError {
            // The code, not just the sentence. `localizedDescription` for an
            // audio session error is "The operation couldn’t be completed",
            // which names nothing: every one of these failures reads the same
            // and there is no way to tell them apart from a phone.
            result(FlutterError(code: "audio",
                                message: "the audio session would not start: "
                                       + "\(error.domain) \(error.code) "
                                       + "\(error.localizedDescription)",
                                details: nil))
            return
        }

        // Preferences, and the name is the whole point: iOS is free to refuse
        // them and usually does. `.voiceChat` sets its own sample rate and its
        // own buffer duration, and asking for 48 kHz or twenty milliseconds on
        // top of it throws on hardware that has already decided otherwise.
        //
        // These used to sit in the block above, so a device that would not take
        // a hint failed the whole call with "the audio session would not
        // start". The rate the device actually gives is handled either way:
        // `captured` converts whatever arrives into the codec's format.
        try? session.setPreferredSampleRate(CallAudio.rate)
        try? session.setPreferredIOBufferDuration(0.02)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: CallAudio.rate,
                                         channels: 1,
                                         interleaved: true) else {
            result(FlutterError(code: "audio",
                                message: "this device will not open 48 kHz mono",
                                details: nil))
            return
        }
        self.format = format

        let input = engine.inputNode
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        player = node

        // The tap size is a request, not a promise: the device delivers what it
        // delivers, so frames are cut to size below rather than assumed.
        input.installTap(onBus: 0,
                         bufferSize: AVAudioFrameCount(CallAudio.frame),
                         format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.captured(buffer, into: format)
        }

        do {
            try engine.start()
            node.play()
            running = true
            dropped = 0
            result(true)
        } catch {
            result(FlutterError(code: "audio",
                                message: error.localizedDescription,
                                details: nil))
        }
    }

    /// Convert whatever the device gave us into frames of exactly `frame`.
    private func captured(_ buffer: AVAudioPCMBuffer, into target: AVAudioFormat) {
        // Capacity scaled by the rate change rather than copied from the input.
        // Converting 16 kHz up to 48 produces three times the frames, and a
        // buffer sized for the input silently truncates two thirds of every
        // one.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let room = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1

        guard let converter = AVAudioConverter(from: buffer.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: room)
        else { return }

        // Handed over once, and then nothing.
        //
        // The block is called whenever the converter wants more input, which is
        // more than once as soon as the device's rate differs from the codec's
        // and the conversion needs additional frames to fill the output. It
        // used to answer `.haveData` with the same buffer every time, so the
        // same twenty milliseconds of microphone was fed in repeatedly and came
        // out as a stutter. `setPreferredSampleRate` is only a request and
        // `.voiceChat` overrides it, so a device running at anything other than
        // 48 kHz met this every frame.
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return }

        guard let channel = out.int16ChannelData?[0] else { return }
        let count = Int(out.frameLength)

        var offset = 0
        while offset + CallAudio.frame <= count {
            let slice = Data(bytes: channel + offset,
                             count: CallAudio.frame * MemoryLayout<Int16>.size)
            lock.lock()
            // The oldest goes, not the newest. A backlog means the encoder is
            // behind, and the frame worth keeping is the one closest to now.
            if ready.count >= CallAudio.backlog {
                ready.removeFirst()
                dropped += 1
            }
            ready.append(slice)
            lock.unlock()
            offset += CallAudio.frame
        }
    }

    private func take(_ result: @escaping FlutterResult) {
        lock.lock()
        let frame = ready.isEmpty ? nil : ready.removeFirst()
        lock.unlock()
        result(frame.map { FlutterStandardTypedData(bytes: $0) })
    }

    private func play(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let pcm = arguments["pcm"] as? FlutterStandardTypedData,
              let format = format,
              let player = player,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(CallAudio.frame))
        else {
            result(false)
            return
        }

        buffer.frameLength = AVAudioFrameCount(CallAudio.frame)
        pcm.data.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress,
                  let destination = buffer.int16ChannelData?[0] else { return }
            destination.update(from: source, count: CallAudio.frame)
        }

        // Scheduled rather than written. `AVAudioPlayerNode` queues, which is
        // what keeps the speaker fed while the network is uneven.
        player.scheduleBuffer(buffer, completionHandler: nil)
        result(true)
    }

    private func route(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let loud = (call.arguments as? [String: Any])?["speaker"] as? Bool ?? false
        do {
            try AVAudioSession.sharedInstance()
                .overrideOutputAudioPort(loud ? .speaker : .none)
            result(true)
        } catch {
            // Routing is a preference. A call that will not switch to the
            // speaker is still a call.
            result(false)
        }
    }

    func stop() {
        guard running else { return }
        running = false

        engine.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine.stop()
        player = nil

        lock.lock()
        ready.removeAll()
        lock.unlock()

        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Held for the length of the sound, because an `AVAudioPlayer` that goes
    /// out of scope stops playing.
    private var tonePlayer: AVAudioPlayer?

    /// The announcement that a call is through, or that it is not.
    ///
    /// Android answers this by playing a resource; there is no resource system
    /// here, so the same two files arrive as Flutter assets and are found by
    /// the key the engine assigns them. Played through the shared session,
    /// which during a call is `.playAndRecord` in `.voiceChat`, so the tone
    /// comes out of whichever the call is using: the earpiece against an ear,
    /// the loudspeaker on speakerphone.
    ///
    /// This case did not exist, and the Dart side caught only
    /// `PlatformException`. An unimplemented method is a
    /// `MissingPluginException`, so every connect and every failure threw
    /// instead of sounding.
    private func tone(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let name = args["name"] as? String,
              name == "connected" || name == "failed" else {
            result(false)
            return
        }

        let key = FlutterDartProject.lookupKey(forAsset: "assets/sound/\(name).wav")
        guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
            result(false)
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            tonePlayer = player
            player.play()
            result(true)
        } catch {
            // A tone is an announcement and never the call itself. Saying no is
            // the whole of the failure.
            result(false)
        }
    }

    func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "permit":
            // Asked when a call starts, not at launch. A microphone prompt on
            // a screen that has not explained the application gets refused.
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { result(granted) }
            }
        case "start": start(result)
        case "take": take(result)
        case "play": play(call, result)
        case "route": route(call, result)
        case "tone": tone(call, result)
        case "dropped": result(dropped)
        case "stop":
            stop()
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }
}
