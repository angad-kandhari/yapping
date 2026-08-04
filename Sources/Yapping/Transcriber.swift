import AudioToolbox
import AVFoundation
import Speech

/// On-device speech-to-text using the macOS 26 SpeechAnalyzer API.
///
/// Audio streams into the analyzer WHILE the user holds fn, so transcription
/// is nearly complete the moment they release. No Whisper, no model files to
/// manage; the OS downloads and owns the speech model.
final class Transcriber {
    /// Per-buffer loudness (RMS), feeds the waveform animations.
    var onLevel: ((Float) -> Void)?
    /// Running transcript (finalized plus the still-refining tail) while the
    /// user talks; feeds the live preview. Arbitrary thread.
    var onPartial: ((String) -> Void)?
    /// Fired on the main queue when the input device changes mid-capture
    /// (AirPods connecting, a USB mic unplugged). The owner should end the
    /// session gracefully; the words spoken so far are still transcribed.
    var onDeviceChange: (() -> Void)?

    private var locale: Locale { Locale(identifier: ConfigStore.shared.localeID) }
    private var engine = AVAudioEngine()
    private var engineObserver: NSObjectProtocol?
    private var capturing = false
    private var needsFreshEngine = false
    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Error>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    init() {
        armEngine()
    }

    deinit {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
    }

    /// Pre-warm and watch. Touching the input node builds the audio graph
    /// now so the first press does not pay that cost with the user's first
    /// word. (prepare() on a graphless engine throws; this does not.)
    ///
    /// The observer is the AirPods fix: connecting them swaps the default
    /// input device out from under the engine. Left unhandled, the next use
    /// of the stale graph trips an AVFoundation format assert -- an ObjC
    /// exception Swift cannot catch -- and kills the whole app.
    private func armEngine() {
        _ = engine.inputNode
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    private func configurationChanged() {
        Log.info("audio configuration changed (input device switched)")
        if capturing {
            // Mid-dictation: the engine already halted itself. Let the owner
            // end the session normally; stop()/abort() rebuild afterwards.
            needsFreshEngine = true
            onDeviceChange?()
        } else {
            rebuildEngine()
        }
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
    func ensureModel() async throws {
        let module = makeModule()
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

        resultsTask = Task { [weak self] in
            var text = ""
            for try await result in module.results {
                let chunk = String(result.text.characters)
                if result.isFinal {
                    text += chunk
                    self?.onPartial?(text)
                } else {
                    self?.onPartial?(text + chunk)
                }
            }
            return text
        }

        if needsFreshEngine { rebuildEngine() }
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
        Log.info("capture start: input \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
        converter = AVAudioConverter(from: inputFormat, to: format)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel?(Self.rms(of: buffer))
            if let converted = self.convert(buffer) {
                self.continuation?.yield(AnalyzerInput(buffer: converted))
            }
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
        analyzer = nil
        module = nil
        resultsTask = nil
        converter = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abort without caring about results (cancelled holds).
    func abort() async {
        stopEngine()
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        analyzer = nil
        module = nil
        resultsTask = nil
        converter = nil
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
        // A device change happened mid-session: the old graph is stale, so
        // re-arm on the new device before the next press
        if needsFreshEngine { rebuildEngine() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let format = analyzerFormat else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
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
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += data[i] * data[i]
        }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}

enum YappingError: Error, LocalizedError {
    case noAudioFormat
    case inputNotReady

    var errorDescription: String? {
        switch self {
        case .noAudioFormat:
            return "No compatible audio format for speech analysis."
        case .inputNotReady:
            return "The microphone is switching devices. Try again in a moment."
        }
    }
}
