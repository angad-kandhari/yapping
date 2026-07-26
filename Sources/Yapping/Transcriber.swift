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
    /// Finalized text chunks, fired progressively during the session.
    var onFinal: ((String) -> Void)?
    /// Volatile (tentative) text, replaced wholesale as recognition refines.
    /// Only fires when the session runs with volatile results enabled.
    var onVolatile: ((String) -> Void)?

    private var locale: Locale { Locale(identifier: ConfigStore.shared.localeID) }
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Error>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private func makeModule() -> SpeechTranscriber {
        // Live modes want responsiveness; volatile guesses only when the
        // maximum-liveness mode will actually type them
        let reporting: Set<SpeechTranscriber.ReportingOption>
        switch ConfigStore.shared.insertionMode {
        case "liveVolatile": reporting = [.volatileResults, .fastResults]
        case "liveFinal": reporting = [.fastResults]
        default: reporting = []
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reporting,
            attributeOptions: []
        )
    }

    /// One-time (per locale): download the on-device speech model if needed.
    func ensureModel() async throws {
        let module = makeModule()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            NSLog("downloading on-device speech model...")
            try await request.downloadAndInstall()
            NSLog("speech model installed")
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
                NSLog("contextual strings not applied: \(error)")
            }
        }

        resultsTask = Task { [weak self] in
            var text = ""
            for try await result in module.results {
                let chunk = String(result.text.characters)
                if result.isFinal {
                    text += chunk
                    self?.onFinal?(chunk)
                } else {
                    self?.onVolatile?(chunk)
                }
            }
            return text
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
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
    }

    /// Stop capture, flush the analyzer, and return the final transcript.
    func stop() async throws -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        analyzer = nil
        module = nil
        resultsTask = nil
        converter = nil
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

enum YappingError: Error {
    case noAudioFormat
}
