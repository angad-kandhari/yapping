import AVFoundation
import Foundation
import Speech

/// Transcribes audio and video files with SpeechAnalyzer. Runs far faster
/// than real time on Apple silicon; a fresh analyzer per job keeps it
/// independent of live dictation.
enum FileTranscriber {
    static func transcribe(url: URL, into model: TranscriptModel) async {
        await MainActor.run {
            model.reset(title: url.lastPathComponent)
            model.running = true
            model.statusLine = "Preparing audio..."
        }
        defer {
            Task { @MainActor in
                model.running = false
            }
        }

        do {
            let audioFile = try await openAudio(url)
            let duration = Double(audioFile.length)
                / audioFile.processingFormat.sampleRate

            let module = SpeechTranscriber(
                locale: Locale(identifier: ConfigStore.shared.localeID),
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange])
            let analyzer = SpeechAnalyzer(modules: [module])

            await MainActor.run { model.statusLine = "Transcribing..." }
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

            var wordCount = 0
            for try await result in module.results where result.isFinal {
                let chunk = String(result.text.characters)
                let seconds = result.range.end.seconds
                wordCount += chunk.split(separator: " ").count
                await MainActor.run {
                    model.finalized += chunk
                    if duration > 0, seconds.isFinite {
                        model.progress = min(1.0, seconds / duration)
                    }
                    model.statusLine = "\(wordCount) words"
                }
            }

            let transcript = await MainActor.run { () -> String in
                model.progress = 1.0
                model.statusLine = "Done. \(wordCount) words from \(Int(duration))s of audio."
                return model.finalized
            }
            if !transcript.isEmpty {
                HistoryStore.shared.add(
                    raw: String(transcript.prefix(2000)),
                    cleaned: String(transcript.prefix(2000)),
                    appName: "File: \(url.lastPathComponent)")
                let storeID = TranscriptStore.shared.add(
                    kind: .file,
                    title: url.lastPathComponent,
                    seconds: duration,
                    words: wordCount,
                    text: transcript)
                await MainActor.run { model.storeID = storeID }
            }
        } catch {
            await MainActor.run {
                model.failure = "Could not transcribe: \(error.localizedDescription)"
                model.statusLine = ""
            }
        }
    }

    /// AVAudioFile opens most audio and video containers directly; for the
    /// ones it refuses, extract the audio track to a temp m4a and retry.
    private static func openAudio(_ url: URL) async throws -> AVAudioFile {
        if let direct = try? AVAudioFile(forReading: url) {
            return direct
        }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "yapping", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This file has no readable audio track."])
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        try await export.export(to: temp, as: .m4a)
        return try AVAudioFile(forReading: temp)
    }
}
