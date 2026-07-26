import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Speech
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fnMonitor = FnKeyMonitor()
    private let transcriber = Transcriber()
    private var statusItem: StatusItem!
    private lazy var settingsWindow = UtilityWindow(title: "Yapping Settings") { SettingsView() }
    private lazy var historyWindow = UtilityWindow(title: "Yapping History") { HistoryView() }
    private lazy var onboardingWindow = UtilityWindow(title: "Welcome to yapping") { OnboardingView() }

    private var busy = false
    private var cancelled = false
    private var pressedAt = Date.distantPast
    private var startTask: Task<Bool, Never>?
    private var maxTimer: Timer?
    private var targetApp: NSRunningApplication?
    private var localeWatcher: AnyCancellable?
    private var hudWatcher: AnyCancellable?
    private var activeStyle: Style?
    private var axSnapshot: Task<(String?, String?), Never>?
    private let hud = WaveformHUD()

    // Live insertion state (insertionMode liveFinal / liveVolatile)
    private var liveMode = false
    private var liveGateOpen = false
    private var pendingChunks: [String] = []
    private var typedFinal = 0
    private var typedVolatile = 0
    private var lastVolatile = ""

    /// Holds shorter than this are accidental taps; discard them.
    private let minHold: TimeInterval = 0.35
    /// Safety stop for a stuck key.
    private let maxHold: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItem(
            onSettings: { [weak self] in self?.settingsWindow.show() },
            onHistory: { [weak self] in self?.historyWindow.show() },
            onSetup: { [weak self] in self?.onboardingWindow.show() },
            onUpdates: { UpdateCheck.run() },
            onQuit: { [weak self] in
                self?.fnMonitor.stop()
                NSApp.terminate(nil)
            }
        )

        // First run, or any missing grant: open the setup assistant
        let ready = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && CGPreflightListenEventAccess()
            && AXIsProcessTrusted()
        if !ready {
            onboardingWindow.show()
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // The waveform only appears while talking; hide it if turned off mid-hold
        hudWatcher = ConfigStore.shared.$hudEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                if !enabled { self?.hud.hide() }
            }

        // Language switches trigger a one-time model download for that locale
        localeWatcher = ConfigStore.shared.$localeID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { try? await self?.transcriber.ensureModel() }
            }
        transcriber.onLevel = { [weak self] level in
            self?.statusItem.pushLevel(level)
            self?.hud.pushLevel(level)
        }
        // Live typing: results hop to the main queue, which serializes them
        transcriber.onFinal = { [weak self] chunk in
            DispatchQueue.main.async { self?.liveFinalArrived(chunk) }
        }
        transcriber.onVolatile = { [weak self] text in
            DispatchQueue.main.async { self?.liveVolatileArrived(text) }
        }

        requestPermissions()

        fnMonitor.onPress = { [weak self] in
            DispatchQueue.main.async { self?.fnPressed() }
        }
        fnMonitor.onRelease = { [weak self] in
            DispatchQueue.main.async { self?.fnReleased() }
        }
        fnMonitor.onCancel = { [weak self] in
            DispatchQueue.main.async { self?.cancelled = true }
        }
        fnMonitor.start()

        Task {
            try? await transcriber.ensureModel()
            await Cleanup.warmUp()
            NSLog("yapping ready: hold the globe/fn key to talk")
        }
    }

    private func requestPermissions() {
        // Microphone prompt up front, not mid-first-dictation
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { NSLog("microphone permission denied") }
        }
        // Some SpeechAnalyzer paths still gate on this; harmless if not
        SFSpeechRecognizer.requestAuthorization { _ in }
        // Accessibility is needed to post the synthetic cmd-V
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("waiting for Accessibility permission (needed to paste)")
        }
    }

    private func fnPressed() {
        guard !busy else { return }
        busy = true
        cancelled = false
        pressedAt = Date()
        // Remember where the text should land, in case focus moves later
        targetApp = NSWorkspace.shared.frontmostApplication
        activeStyle = Style.match(
            ConfigStore.shared.styles, bundleID: targetApp?.bundleIdentifier)

        // AX reads (selection for voice editing, field text for context)
        // happen off the critical path; a hung app must not delay the mic
        let wantContext = ConfigStore.shared.useFieldContext
        axSnapshot = Task.detached(priority: .userInitiated) {
            let selection = AXContext.selectedText()
            let context = wantContext ? AXContext.fieldContext() : nil
            return (selection, context)
        }

        // Live insertion: hold the first keystrokes until we know whether a
        // selection exists (a selection means this hold is a voice edit)
        liveMode = ConfigStore.shared.insertionMode != "release"
        liveGateOpen = false
        pendingChunks = []
        typedFinal = 0
        typedVolatile = 0
        lastVolatile = ""
        if liveMode {
            Task { [weak self] in
                let (selection, _) = await self?.axSnapshot?.value ?? (nil, nil)
                DispatchQueue.main.async {
                    guard let self, self.liveMode, self.busy else { return }
                    if let selection, !selection.isEmpty {
                        // Voice edit takes priority; classic path handles it
                        self.liveMode = false
                        self.pendingChunks = []
                    } else {
                        self.liveGateOpen = true
                        let buffered = self.pendingChunks
                        self.pendingChunks = []
                        buffered.forEach { self.typeFinalChunk($0) }
                    }
                }
            }
        }

        statusItem.setState(.recording, detail: activeStyle?.name)
        if ConfigStore.shared.hudEnabled { hud.show() }
        Sound.play("Pop")

        startTask = Task {
            do {
                try await transcriber.start()
                return true
            } catch {
                NSLog("could not start recording: \(error)")
                return false
            }
        }
        maxTimer = Timer.scheduledTimer(withTimeInterval: maxHold, repeats: false) { [weak self] _ in
            self?.fnReleased()
        }
    }

    private func fnReleased() {
        guard busy else { return }
        maxTimer?.invalidate()
        maxTimer = nil
        if Date().timeIntervalSince(pressedAt) < minHold {
            cancelled = true
        }

        let wasCancelled = cancelled
        hud.hide()
        statusItem.setState(wasCancelled ? .idle : .processing)
        if !wasCancelled { Sound.play("Tink") }

        Task {
            defer {
                busy = false
                liveMode = false
                statusItem.setState(.idle)
            }
            let started = await startTask?.value ?? false
            guard started else {
                Sound.play("Basso")
                await transcriber.abort()
                return
            }
            if wasCancelled {
                // A live hold may already have typed text; take it back
                await MainActor.run {
                    let typed = self.typedFinal + self.typedVolatile
                    if typed > 0 { Typist.backspace(typed) }
                    self.typedFinal = 0
                    self.typedVolatile = 0
                }
                await transcriber.abort()
                return
            }
            if self.liveMode {
                await self.finishLiveHold()
                return
            }
            do {
                let text = try await transcriber.stop()
                guard !text.isEmpty else {
                    Sound.play("Basso")
                    return
                }
                let (selection, fieldContext) = await self.axSnapshot?.value ?? (nil, nil)

                let output: String
                if let selection, !selection.isEmpty {
                    // Voice edit: the spoken words are an instruction applied
                    // to the selected text; pasting replaces the selection
                    self.statusItem.setState(.processing, detail: "Editing selection")
                    guard let edited = await Cleanup.rewrite(
                        selection: selection, instruction: text) else {
                        Sound.play("Basso")
                        Self.notify("Edit failed",
                                    body: "Selection left unchanged. Is Ollama running?")
                        return
                    }
                    output = edited
                } else if self.activeStyle?.verbatim == true {
                    output = ConfigStore.shared.applyTextRules(to: text)
                } else {
                    let cleaned = await Cleanup.polish(
                        text, style: self.activeStyle, fieldContext: fieldContext)
                    output = ConfigStore.shared.applyTextRules(to: cleaned)
                }
                guard !self.cancelled else { return }

                // If the user switched apps while transcribing, put the text
                // where they were when they started talking
                if let target = self.targetApp,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier
                       != target.processIdentifier {
                    target.activate()
                    try? await Task.sleep(for: .milliseconds(180))
                }
                // Trailing space so consecutive dictations don't run together
                // (not for edits, which replace the selection exactly)
                let isEdit = selection?.isEmpty == false
                Paster.paste(isEdit ? output : output + " ")
                HistoryStore.shared.add(
                    raw: text, cleaned: output,
                    appName: self.targetApp?.localizedName ?? "Unknown")
            } catch {
                NSLog("dictation error: \(error)")
                Sound.play("Basso")
                Self.notify("Dictation failed", body: "\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Live insertion

    private func liveFinalArrived(_ chunk: String) {
        guard liveMode, busy, !cancelled else { return }
        guard liveGateOpen else {
            pendingChunks.append(chunk)
            return
        }
        typeFinalChunk(chunk)
    }

    private func typeFinalChunk(_ chunk: String) {
        // Finalized text supersedes whatever volatile guess is on screen
        if typedVolatile > 0 {
            Typist.backspace(typedVolatile)
            typedVolatile = 0
            lastVolatile = ""
        }
        let processed = ConfigStore.shared.applyTextRules(to: chunk)
        Typist.type(processed)
        typedFinal += processed.count
    }

    private func liveVolatileArrived(_ text: String) {
        guard liveMode, busy, liveGateOpen, !cancelled else { return }
        // Retype only the suffix that changed since the last guess
        let common = zip(lastVolatile, text).prefix { $0.0 == $0.1 }.count
        Typist.backspace(lastVolatile.count - common)
        Typist.type(String(text.dropFirst(common)))
        typedVolatile = text.count
        lastVolatile = text
    }

    private func finishLiveHold() async {
        do {
            // stop() flushes the tail through onFinal; the queued main-thread
            // hops below then run before our fence, so ordering holds
            let text = try await transcriber.stop()
            await MainActor.run {
                if self.typedVolatile > 0 {
                    Typist.backspace(self.typedVolatile)
                    self.typedVolatile = 0
                }
                if self.typedFinal > 0 {
                    // Trailing space so consecutive dictations don't run together
                    Typist.type(" ")
                }
            }
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                Sound.play("Basso")
                return
            }
            HistoryStore.shared.add(
                raw: transcript, cleaned: transcript,
                appName: targetApp?.localizedName ?? "Unknown")
        } catch {
            NSLog("live dictation error: \(error)")
            Sound.play("Basso")
        }
    }

    static func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }
}

enum Sound {
    static func play(_ name: String) {
        guard ConfigStore.shared.soundsEnabled else { return }
        NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)?.play()
    }
}
