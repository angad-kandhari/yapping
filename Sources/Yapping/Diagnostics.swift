import AVFoundation
import AppKit
import Speech
import SwiftUI

/// Live microphone level, shared by anything that wants to draw a meter.
/// During a real dictation this is fed for free by Transcriber.onLevel, so
/// the diagnostics meter never needs its own audio engine while you talk.
@MainActor
final class LevelBus: ObservableObject {
    static let shared = LevelBus()
    @Published var level: Float = 0
    @Published var lastAudioAt: Date?

    func push(_ level: Float) {
        self.level = level
        if level > 0.0005 { lastAudioAt = Date() }
    }
}

/// A short-lived, tap-only engine for the "test microphone" button.
///
/// Everything Transcriber learned the hard way applies here too: watch for
/// configuration changes, and never install a tap on a zero-sample-rate
/// format. A second engine that skips those reopens the AirPods crash.
final class MicMonitor {
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private(set) var running = false

    func start() throws {
        guard !running else { return }
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw YappingError.inputNotReady
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Log.info("mic monitor: audio configuration changed, stopping")
            self?.stop()
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            let rms = AudioLevel.rms(of: buffer)
            Task { @MainActor in LevelBus.shared.push(rms) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        running = false
    }
}

/// Loudness of a buffer, shared by the transcriber and the mic monitor.
enum AudioLevel {
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += data[i] * data[i]
        }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}

// MARK: - Self test

struct DiagnosticStage: Identifiable {
    enum Result { case pending, running, pass, warn, fail }
    let id = UUID()
    let name: String
    var result: Result = .pending
    var detail: String = ""
    var ms: Int?
}

@MainActor
final class Diagnostics: ObservableObject {
    @Published var stages: [DiagnosticStage] = []
    @Published var running = false

    func runSelfTest() async {
        guard !running else { return }
        running = true
        stages = [
            DiagnosticStage(name: "Permissions"),
            DiagnosticStage(name: "Input device"),
            DiagnosticStage(name: "Speech model"),
            DiagnosticStage(name: "Microphone hears something"),
            DiagnosticStage(name: "Transcription"),
            DiagnosticStage(name: "Cleanup provider"),
        ]
        defer { running = false }

        await stage(0) {
            guard Permissions.all else {
                var missing: [String] = []
                if !Permissions.microphone { missing.append("microphone") }
                if !Permissions.inputMonitoring { missing.append("input monitoring") }
                if !Permissions.accessibility { missing.append("accessibility") }
                if !Permissions.globeKeyFree { missing.append("globe key set to Do Nothing") }
                return (.fail, "Missing: " + missing.joined(separator: ", "))
            }
            return (.pass, "All four grants in place")
        }

        await stage(1) {
            let pinned = ConfigStore.shared.micDeviceUID
            let device = pinned.isEmpty
                ? AudioDevices.defaultInput()
                : AudioDevices.inputs().first { $0.uid == pinned } ?? AudioDevices.defaultInput()
            guard let device else { return (.fail, "No input device could be resolved") }
            guard let format = AudioDevices.format(forUID: device.uid) else {
                return (.warn, "\(device.name), but its format could not be read")
            }
            let note = format.channels > 1
                ? "\(device.name), \(Int(format.sampleRate)) Hz, \(format.channels) ch (downmixed to mono)"
                : "\(device.name), \(Int(format.sampleRate)) Hz, mono"
            guard format.sampleRate > 0, format.channels > 0 else {
                return (.fail, "\(device.name) reports an unusable format")
            }
            return (.pass, note)
        }

        await stage(2) {
            let locale = Locale(identifier: ConfigStore.shared.localeID)
            let module = SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                reportingOptions: [], attributeOptions: [])
            do {
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [module])
                return request == nil
                    ? (.pass, "Installed for \(locale.identifier)")
                    : (.warn, "Not downloaded yet for \(locale.identifier)")
            } catch {
                return (.fail, "\(error.localizedDescription)")
            }
        }

        await stage(3) {
            guard !ActivationPolicy.isDictating else {
                return (.warn, "Skipped: a dictation is in progress")
            }
            let monitor = MicMonitor()
            do {
                try monitor.start()
            } catch {
                return (.fail, "Could not open the microphone: \(error.localizedDescription)")
            }
            var peak: Float = 0
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                peak = max(peak, LevelBus.shared.level)
            }
            monitor.stop()
            if peak < 0.0005 {
                return (.fail, "Three seconds of silence. Check the input device, or that the mic is not muted.")
            }
            return (.pass, String(format: "Peak level %.3f", peak))
        }

        await stage(4) {
            guard !ActivationPolicy.isDictating else {
                return (.warn, "Skipped: a dictation is in progress")
            }
            // The stage that exercises the real converter and downmix path
            let transcriber = Transcriber()
            do {
                try await transcriber.start()
                try? await Task.sleep(for: .seconds(3))
                let text = try await transcriber.stop()
                return text.isEmpty
                    ? (.warn, "Ran clean but heard no words. If you spoke, this is the bug worth reporting.")
                    : (.pass, "Heard: \(text.prefix(60))")
            } catch {
                return (.fail, "\(error.localizedDescription)")
            }
        }

        await stage(5) {
            guard ConfigStore.shared.cleanupEnabled else {
                return (.warn, "Cleanup is turned off, so raw transcripts are pasted")
            }
            let sample = "um so i think we should ship it"
            let cleaned = await Cleanup.polish(text: sample)
            if cleaned == sample {
                return (.warn, "The provider did not respond; raw transcripts will be used. \(Cleanup.providerHint)")
            }
            return (.pass, "\(cleaned)")
        }
    }

    private func stage(
        _ index: Int, _ work: () async -> (DiagnosticStage.Result, String)
    ) async {
        guard stages.indices.contains(index) else { return }
        stages[index].result = .running
        let started = Date()
        let (result, detail) = await work()
        stages[index].result = result
        stages[index].detail = detail
        stages[index].ms = Int(Date().timeIntervalSince(started) * 1000)
    }

    /// A paste-safe summary for bug reports. Deliberately excludes anything
    /// the user dictated.
    func report() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var lines = [
            "yapping \(version) on \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "provider: \(ConfigStore.shared.cleanupProvider)",
            "permissions: mic \(Permissions.microphone), input \(Permissions.inputMonitoring), ax \(Permissions.accessibility), globe \(Permissions.globeKeyFree)",
        ]
        if let device = AudioDevices.defaultInput() {
            let format = AudioDevices.format(forUID: device.uid)
            lines.append("input: \(device.name) \(format.map { "\(Int($0.sampleRate)) Hz, \($0.channels) ch" } ?? "format unknown")")
        }
        for stage in stages {
            lines.append("\(stage.name): \(stage.result) \(stage.detail)")
        }
        lines.append("recent errors:")
        lines.append(contentsOf: Log.recentErrors(limit: 15))
        return lines.joined(separator: "\n")
    }
}

// MARK: - The pane

struct DiagnosticsPane: View {
    @StateObject private var diagnostics = Diagnostics()
    @ObservedObject private var levels = LevelBus.shared
    @ObservedObject private var config = ConfigStore.shared
    @State private var monitor = MicMonitor()
    @State private var monitoring = false
    @State private var micTestError: String?
    @State private var providerOK: Bool?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(title: "diagnostics",
                           sub: "what yapping can see, hear, and reach right now")

                permissionsCard
                audioCard
                providerCard
                selfTestCard
                errorsCard
            }
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
        .task {
            // Keep the dot honest: this is the pane people stare at while
            // starting or stopping their provider, so a one-shot check lies
            while !Task.isCancelled {
                providerOK = await Cleanup.reachable() || Cleanup.appleAvailable
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onDisappear { monitor.stop(); monitoring = false }
    }

    // MARK: Cards

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Permissions")
            row("Microphone", Permissions.microphone)
            row("Input monitoring", Permissions.inputMonitoring)
            row("Accessibility", Permissions.accessibility)
            row("Globe key set to Do Nothing", Permissions.globeKeyFree)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCard()
    }

    private var audioCard: some View {
        let pinned = config.micDeviceUID
        let device = pinned.isEmpty
            ? AudioDevices.defaultInput()
            : AudioDevices.inputs().first { $0.uid == pinned }
        let format = device.flatMap { AudioDevices.format(forUID: $0.uid) }
        return VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Audio input")
            if let device {
                Text(device.name).font(.callout).fontWeight(.medium)
                Text(pinned.isEmpty ? "System default" : "Pinned in Settings")
                    .font(.caption).foregroundStyle(.secondary)
                if let format {
                    Text("\(Int(format.sampleRate)) Hz, \(format.channels) channel\(format.channels == 1 ? "" : "s")"
                         + (format.channels > 1 ? ", downmixed to mono for the recognizer" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No input device resolved.").foregroundStyle(.orange).font(.callout)
            }

            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Brand.accent)
                            .frame(width: geo.size.width * CGFloat(min(1, levels.level * 25)))
                    }
                }
                .frame(height: 8)
                Button(monitoring ? "Stop" : "Test microphone") { toggleMonitor() }
                    .controlSize(.small)
                    .disabled(ActivationPolicy.isDictating)
            }
            if monitoring, let last = levels.lastAudioAt, Date().timeIntervalSince(last) > 3 {
                Text("No audio for three seconds. That is the same symptom as a muted or wrong input device.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let micTestError {
                Text(micTestError).font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCard()
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Cleanup provider")
            HStack(spacing: 7) {
                Circle().fill(providerOK == true ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(providerLabel).font(.callout)
            }
            if !config.cleanupEnabled {
                Text("Cleanup is off, so raw transcripts are pasted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCard()
    }

    private var providerLabel: String {
        switch config.cleanupProvider {
        case "apple": return Cleanup.appleAvailable
            ? "Apple Intelligence is available" : "Apple Intelligence is off, Ollama is the fallback"
        case "custom": return config.customBaseURL.isEmpty
            ? "No custom endpoint set" : config.customBaseURL
        default: return providerOK == true
            ? "Ollama answering at \(config.ollamaHost)" : "Ollama not answering at \(config.ollamaHost)"
        }
    }

    private var selfTestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MonoLabel("Self test")
                Spacer()
                Button(diagnostics.running ? "Running..." : "Run self test") {
                    Task { await diagnostics.runSelfTest() }
                }
                .disabled(diagnostics.running)
                .controlSize(.small)
            }
            if diagnostics.stages.isEmpty {
                Text("Runs the whole path end to end: permissions, the input device, the speech model, three seconds of real recording, a real transcription, and a cleanup round trip. Speak while it records so the transcription stage has something to hear.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics.stages) { stage in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(stage.result))
                            .foregroundStyle(color(stage.result))
                            .font(.caption)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(stage.name).font(.callout).fontWeight(.medium)
                                if let ms = stage.ms {
                                    Text("\(ms) ms").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            if !stage.detail.isEmpty {
                                Text(stage.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button(copied ? "Copied" : "Copy diagnostics report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostics.report(), forType: .string)
                    copied = true
                    // Reset so a second copy confirms again
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .controlSize(.small)
                Text("The report holds versions, permissions, device details, and error lines. It never includes anything you dictated.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCard()
    }

    private var errorsCard: some View {
        let errors = Log.recentErrors(limit: 8)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoLabel("Recent errors")
                Spacer()
                Button("Reveal log file") { Log.reveal() }.controlSize(.small)
            }
            if errors.isEmpty {
                Text("None logged.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(errors, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCard()
    }

    // MARK: Helpers

    private func row(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.caption)
            Text(label).font(.callout)
            Spacer()
        }
    }

    private func toggleMonitor() {
        micTestError = nil
        if monitoring {
            monitor.stop()
            monitoring = false
        } else {
            do {
                try monitor.start()
                monitoring = true
            } catch {
                Log.error("mic test could not start: \(error)")
                micTestError = "The test could not open the microphone: \(error.localizedDescription)"
            }
        }
    }

    private func icon(_ result: DiagnosticStage.Result) -> String {
        switch result {
        case .pending: return "circle"
        case .running: return "circle.dotted"
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        }
    }

    private func color(_ result: DiagnosticStage.Result) -> Color {
        switch result {
        case .pending, .running: return .secondary
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
}
