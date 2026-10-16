import AudioToolbox
import AVFoundation
import Speech

/// On-device speech-to-text using the macOS 26 SpeechAnalyzer API.
///
/// Audio streams into the analyzer WHILE the user holds fn, so transcription
/// is nearly complete the moment they release. No Whisper, no model files to
/// manage; the OS downloads and owns the speech model.
///
/// An actor, because every piece of state here used to be touched from
/// three places at once: the capture task (start/stop), the main thread
/// (configuration-change notifications swapping the engine) and the audio
/// tap thread. The tap thread never touches the actor: it talks to a
/// `CaptureSink` built once per capture, which owns the converter and the
/// stream continuation and nothing else.
actor Transcriber {
    /// Per-buffer loudness (RMS), feeds the waveform animations. Audio thread.
    private let onLevel: ((Float) -> Void)?
    /// Running transcript (finalized plus the still-refining tail) while the
    /// user talks; feeds the live preview. Arbitrary thread.
    private let onPartial: ((String) -> Void)?
    /// Fired when the input device changed mid-capture and capture could
    /// NOT be re-armed on the new device. The owner should end the session;
    /// the words spoken so far are still transcribed.
    private let onDeviceChange: (() -> Void)?

    private var locale: Locale { Locale(identifier: ConfigStore.shared.localeID) }
    private var engine = AVAudioEngine()
    private var engineObserver: NSObjectProtocol?
    private var capturing = false
    /// True until the first `warm()` or `start()` builds the graph and
    /// registers the configuration observer; an actor's init cannot do
    /// that itself (the observer closure needs self).
    private var needsFreshEngine = true
    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Error>?
    private var analyzerFormat: AVAudioFormat?
    private var sink: CaptureSink?
    /// Re-arms this capture has survived; see `configurationChanged`.
    private var rearms = 0
    /// Bluetooth headsets can flip profiles twice while settling. Past this
    /// the device is genuinely unstable and the session ends instead.
    private static let maxRearms = 3

    init(
        onLevel: ((Float) -> Void)? = nil,
        onPartial: ((String) -> Void)? = nil,
        onDeviceChange: (() -> Void)? = nil
    ) {
        self.onLevel = onLevel
        self.onPartial = onPartial
        self.onDeviceChange = onDeviceChange
    }

    /// Pre-warm: touching the input node builds the audio graph now so the
    /// first press does not pay that cost with the user's first word.
    /// (prepare() on a graphless engine throws; this does not.)
    func warm() {
        if needsFreshEngine { rebuildEngine() }
    }

    deinit {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
    }

    /// The observer is the AirPods fix: connecting them swaps the default
    /// input device out from under the engine. Left unhandled, the next use
    /// of the stale graph trips an AVFoundation format assert, an ObjC
    /// exception Swift cannot catch, and kills the whole app.
    private nonisolated static func observe(
        _ engine: AVAudioEngine, _ body: @escaping @Sendable () -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { _ in body() }
    }

    private func armEngine() {
        _ = engine.inputNode
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
        engineObserver = Self.observe(engine) { [weak self] in
            Task { await self?.configurationChanged() }
        }
    }

    private func configurationChanged() {
        guard capturing else {
            releaseEngine()
            return
        }
        // Mid-dictation. Measured on this machine: on Bluetooth headphones
        // the change arrives 0.3 to 0.8 s after capture starts, because
        // opening the input flips the headset into its hands-free profile.
        // Ending the session here meant every first dictation on AirPods
        // died with nothing said. Instead, keep the analyzer and its input
        // stream alive and re-open capture on the device as it is now.
        rearms += 1
        guard rearms <= Self.maxRearms else {
            Log.error("input device changed \(rearms) times in one dictation; giving up on this session")
            capturing = false
            needsFreshEngine = true
            onDeviceChange?()
            return
        }
        do {
            try rearmCapture()
        } catch {
            Log.error("could not re-arm capture after a device change: \(error)")
            capturing = false
            needsFreshEngine = true
            onDeviceChange?()
        }
    }

    /// Idle and the device changed: let go of the device and rebuild on the
    /// next press, never now. Rebuilding here re-opens the input on the new
    /// device, and on Bluetooth headphones that opening is itself a
    /// configuration change (the headset flips between its stereo and
    /// hands-free profiles), so an eager rebuild fed its own notification:
    /// measured at four rebuilds a second for minutes on AirPods Max,
    /// during which the headphones could not hold a profile and playback
    /// from other apps went silent. Deferring costs the next press about
    /// 40 ms (measured) for the engine build, once.
    private func releaseEngine() {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        engine.stop()
        engine = AVAudioEngine()
        if !needsFreshEngine {
            Log.info("audio configuration changed while idle; engine released until next press")
        }
        needsFreshEngine = true
    }

    private func rebuildEngine() {
        engine.stop()
        engine = AVAudioEngine()
        needsFreshEngine = false
        armEngine()
    }

    private func makeModule() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    /// One-time (per locale): download the on-device speech model if needed.
    /// The locale is reserved so the system keeps its assets allocated
    /// between launches; without the reservation every launch logged a fresh
    /// "download", which took up to 3.5 s on this machine.
    func ensureModel() async throws {
        warm()
        let module = makeModule()
        let locale = self.locale
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier == locale.identifier }) {
            do {
                _ = try await AssetInventory.reserve(locale: locale)
            } catch {
                Log.error("could not reserve speech assets for \(locale.identifier): \(error)")
            }
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.info("downloading on-device speech model...")
            try await request.downloadAndInstall()
            Log.info("speech model installed")
        }
    }

    /// Start capturing the mic and streaming into the analyzer.
    func start() async throws {
        let module = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module])
        self.module = module
        self.analyzer = analyzer
        rearms = 0

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw YappingError.noAudioFormat
        }
        analyzerFormat = format

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont
        try await analyzer.start(inputSequence: stream)

        // Bias recognition toward the personal dictionary (names, jargon)
        let words = ConfigStore.shared.dictionary
        if !words.isEmpty {
            do {
                let context = AnalysisContext()
                context.contextualStrings[.general] = words
                try await analyzer.setContext(context)
            } catch {
                Log.error("contextual strings not applied: \(error)")
            }
        }

        let onPartial = self.onPartial
        resultsTask = Task {
            var text = ""
            for try await result in module.results {
                let chunk = String(result.text.characters)
                if result.isFinal {
                    text += chunk
                    onPartial?(text)
                } else {
                    onPartial?(text + chunk)
                }
            }
            return text
        }

        if needsFreshEngine { rebuildEngine() }
        try openCapture(label: "capture start")
    }

    /// The input device changed under a live capture: throw the halted graph
    /// away and open the device as it is now, feeding the same analyzer.
    private func rearmCapture() throws {
        engine.inputNode.removeTap(onBus: 0)
        rebuildEngine()
        try openCapture(label: "capture re-armed after a device change")
    }

    /// Resolve the input format, build the converter and sink, install the
    /// tap and start the engine. Shared by the first start and every re-arm.
    private func openCapture(label: String) throws {
        guard let format = analyzerFormat, let continuation else {
            throw YappingError.inputNotReady
        }
        var input = engine.inputNode
        applyMicPin(input)
        var inputFormat = input.outputFormat(forBus: 0)
        // Mid device-switch the node can report 0 Hz / 0 channels, and
        // installTap with that format is an uncatchable assert. One rebuild
        // usually lands on the new device; if not, fail soft (Basso, no
        // paste) instead of crashing.
        if inputFormat.sampleRate <= 0 || inputFormat.channelCount == 0 {
            rebuildEngine()
            input = engine.inputNode
            applyMicPin(input)
            inputFormat = input.outputFormat(forBus: 0)
        }
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Log.error("input device not ready: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
            throw YappingError.inputNotReady
        }
        guard let sink = CaptureSink(
            inputFormat: inputFormat, analyzerFormat: format,
            continuation: continuation, onLevel: onLevel) else {
            Log.error("no converter from \(inputFormat) to \(format)")
            throw YappingError.inputNotReady
        }
        self.sink = sink
        Log.info("\(label): input \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            sink.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        capturing = true
    }

    /// Stop capture, flush the analyzer, and return the final transcript.
    func stop() async throws -> String {
        stopEngine()
        continuation?.finish()
        continuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = try await resultsTask?.value ?? ""
        clearSession()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abort without caring about results (cancelled holds).
    func abort() async {
        stopEngine()
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        clearSession()
    }

    private func clearSession() {
        analyzer = nil
        module = nil
        resultsTask = nil
        sink = nil
    }

    /// Pin capture to the user's chosen device (Settings > Speech), applied
    /// before the format is read so the tap and converter see the pinned
    /// device's format. Missing device = quiet fallback to system default,
    /// so an unplugged USB mic never blocks dictation.
    private func applyMicPin(_ input: AVAudioInputNode) {
        let uid = ConfigStore.shared.micDeviceUID
        guard !uid.isEmpty else { return }
        guard let resolved = AudioDevices.deviceID(forUID: uid),
              let unit = input.audioUnit else {
            Log.info("pinned mic '\(uid)' not present; using system default")
            return
        }
        var deviceID = resolved
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr {
            Log.info("mic pinned to '\(uid)'")
        } else {
            Log.error("mic pin failed (\(status)); using system default")
        }
    }

    private func stopEngine() {
        capturing = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // A device change happened mid-session: the old graph is stale.
        // Leave it flagged; start() rebuilds on the next press. Rebuilding
        // here would touch the device while idle, see releaseEngine.
    }
}

/// Everything the audio tap thread needs, and nothing it must not touch.
/// Built once per capture (and again on every re-arm, because the input
/// format may have changed); the actor never reaches into it after that.
private final class CaptureSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let analyzerFormat: AVAudioFormat
    /// Set when the mic is multichannel (raw 3-mic array, USB interfaces):
    /// buffers are hand-mixed to this mono format before the converter,
    /// which silently drops multichannel input otherwise.
    private let monoFormat: AVAudioFormat?
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: ((Float) -> Void)?
    /// Only ever read and written on the tap thread.
    private var loggedConvertError = false

    init?(inputFormat: AVAudioFormat, analyzerFormat: AVAudioFormat,
          continuation: AsyncStream<AnalyzerInput>.Continuation,
          onLevel: ((Float) -> Void)?) {
        monoFormat = inputFormat.channelCount > 1
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32,
                            sampleRate: inputFormat.sampleRate,
                            channels: 1, interleaved: false)
            : nil
        guard let converter = AVAudioConverter(
            from: monoFormat ?? inputFormat, to: analyzerFormat) else { return nil }
        self.converter = converter
        self.analyzerFormat = analyzerFormat
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        onLevel?(AudioLevel.rms(of: buffer))
        if let converted = convert(buffer) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = downmixIfNeeded(buffer) else { return nil }
        let ratio = analyzerFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            return nil
        }
        var served = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if served {
                status.pointee = .noDataNow
                return nil
            }
            served = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, out.frameLength > 0 else {
            // Once per session: a silent converter is an inaudible failure
            // (bars dance, transcript empty) and cost a day to diagnose
            if !loggedConvertError {
                loggedConvertError = true
                Log.error("audio conversion failing: \(error?.localizedDescription ?? "no frames out")")
            }
            return nil
        }
        return out
    }

    /// Average all channels into mono. The recognizer wants one channel;
    /// AVAudioConverter drops multichannel buffers on the floor instead of
    /// downmixing them.
    private func downmixIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let monoFormat, buffer.format.channelCount > 1 else {
            return buffer
        }
        guard let src = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        for i in 0..<frames {
            var sum: Float = 0
            for ch in 0..<channels { sum += src[ch][i] }
            dst[0][i] = sum / Float(channels)
        }
        mono.frameLength = buffer.frameLength
        return mono
    }
}

enum YappingError: Error, LocalizedError {
    case noAudioFormat
    case inputNotReady
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .noAudioFormat:
            return "No compatible audio format for speech analysis."
        case .inputNotReady:
            return "The microphone is switching devices. Try again in a moment."
        case .timedOut(let step):
            return "\(step) did not finish in time."
        }
    }
}

/// Run `body` with a hard deadline. The body keeps running if it is not
/// cancellable (a hung CoreAudio call, say); what matters is that the
/// caller gets control back and can reset its own state. Before this
/// existed, one stalled stop() left the hotkey dead until relaunch.
///
/// Unstructured on purpose: a task group waits for every child before it
/// returns, so a group-based race only reported the timeout once the
/// blocked call had finished anyway. Measured: opening the AirPods Max
/// microphone while they were streaming video blocked for 29 s, and the
/// "10 s" deadline fired at 29 s.
func withDeadline<T: Sendable>(
    seconds: Double, step: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let settled = DeadlineFlag()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do {
                let value = try await body()
                if settled.claim() { continuation.resume(returning: value) }
            } catch {
                if settled.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if settled.claim() {
                work.cancel()
                continuation.resume(throwing: YappingError.timedOut(step))
            }
        }
    }
}

/// Whichever side of the race finishes first resumes the continuation;
/// the other finds the flag already claimed and does nothing.
private final class DeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
