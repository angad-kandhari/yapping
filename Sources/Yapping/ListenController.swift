import AVFoundation
import Foundation
import Speech

/// Listen mode: transcribes whatever the Mac is playing (lectures,
/// podcasts, the remote side of calls) into the transcript window.
/// Independent of fn dictation; both can run at once. Transcripts stay
/// raw: no LLM pass over an hour of lecture.
final class ListenController {
    let model = TranscriptModel()
    private(set) var active = false

    private let source = ProcessTapSource()
    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var startedAt = Date.distantPast

    var onStateChange: ((Bool) -> Void)?

    func toggle() {
        active ? stop() : start()
    }

    func start() {
        guard !active else { return }
        model.reset(title: "Listening to system audio")
        model.running = true
        startedAt = Date()

        Task {
            do {
                let module = SpeechTranscriber(
                    locale: Locale(identifier: ConfigStore.shared.localeID),
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: [])
                let analyzer = SpeechAnalyzer(modules: [module])
                self.module = module
                self.analyzer = analyzer

                guard let analyzerFormat = await SpeechAnalyzer
                    .bestAvailableAudioFormat(compatibleWith: [module]) else {
                    throw YappingError.noAudioFormat
                }

                let (input, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
                inputContinuation = inputCont
                try await analyzer.start(inputSequence: input)

                // Results into the window: finals accumulate, volatile replaces
                resultsTask = Task { [weak self] in
                    guard let self, let module = self.module else { return }
                    do {
                        for try await result in module.results {
                            let chunk = String(result.text.characters)
                            await MainActor.run {
                                if result.isFinal {
                                    self.model.finalized += chunk
                                    self.model.volatileTail = ""
                                } else {
                                    self.model.volatileTail = chunk
                                }
                                self.updateStatus()
                            }
                        }
                    } catch {
                        NSLog("listen results error: \(error)")
                    }
                }

                // Tap buffers, converted to the analyzer's format
                let buffers = try source.start()
                pumpTask = Task { [weak self] in
                    var converter: AVAudioConverter?
                    for await buffer in buffers {
                        guard let self, self.active else { break }
                        if converter == nil {
                            converter = AVAudioConverter(
                                from: buffer.format, to: analyzerFormat)
                        }
                        guard let converter,
                              let converted = Self.convert(
                                buffer, with: converter, to: analyzerFormat)
                        else { continue }
                        self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
                    }
                }

                await MainActor.run {
                    self.active = true
                    self.model.statusLine = "Listening..."
                    self.onStateChange?(true)
                }
            } catch {
                source.stop()
                await MainActor.run {
                    self.model.running = false
                    self.model.failure = error.localizedDescription
                    self.onStateChange?(false)
                }
            }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        source.stop()
        pumpTask?.cancel()

        Task {
            inputContinuation?.finish()
            inputContinuation = nil
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            // Results loop drains the tail, then ends on its own
            _ = await resultsTask?.value
            analyzer = nil
            module = nil

            await MainActor.run {
                model.running = false
                model.volatileTail = ""
                updateStatus(final: true)
                onStateChange?(false)
                if !model.finalized.isEmpty {
                    HistoryStore.shared.add(
                        raw: String(model.finalized.prefix(500)),
                        cleaned: String(model.finalized.prefix(500)),
                        appName: "Listen")
                }
            }
        }
    }

    private func updateStatus(final: Bool = false) {
        let words = model.finalized.split(separator: " ").count
        let minutes = Int(Date().timeIntervalSince(startedAt) / 60)
        model.statusLine = final
            ? "Stopped. \(words) words in \(max(1, minutes)) min."
            : "Listening... \(words) words, \(minutes) min"
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
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
}
