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
    private lazy var mainWindow = UtilityWindow(title: "Yapping") { MainWindowView() }
    private lazy var onboardingWindow = UtilityWindow(title: "Welcome to yapping") {
        OnboardingView(startOnTour: OnboardingView.allPermissionsGranted())
    }
    private lazy var updatesWindow = UtilityWindow(title: "Yapping Updates") { UpdatesView() }
    private let listenController = ListenController()
    private let fileModel = TranscriptModel()
    private lazy var fileWindow = UtilityWindow(title: "Yapping Transcript") {
        [weak self] in TranscriptView(model: self?.fileModel ?? TranscriptModel())
    }
    private lazy var listenWindow = UtilityWindow(title: "Yapping Listen") {
        [weak self] in
        TranscriptView(
            model: self?.listenController.model ?? TranscriptModel(),
            onStop: { self?.listenController.stop() })
    }

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

    // Hands-free (double-tap) session state
    private var handsFree = false
    private var pendingTapTimer: Timer?
    private var ignoreNextRelease = false
    private var lastVoiceAt = Date.distantPast

    /// Holds shorter than this are accidental taps; discard them.
    private let minHold: TimeInterval = 0.35
    /// Safety stop for a stuck key.
    private let maxHold: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        MoveToApplications.offerIfNeeded()

        statusItem = StatusItem(
            onSettings: { [weak self] in self?.openMain(.settings) },
            onHistory: { [weak self] in self?.openMain(.dictations) },
            onTranscribeFile: { [weak self] in self?.pickAndTranscribeFile() },
            onListen: { [weak self] in
                self?.listenController.toggle()
                self?.listenWindow.show()
            },
            onSetup: { [weak self] in self?.onboardingWindow.show() },
            onUpdates: { [weak self] in
                UpdateCheck.markSeen()
                self?.statusItem.setUpdateAvailable(false)
                self?.updatesWindow.show()
            },
            onQuit: { [weak self] in
                self?.fnMonitor.stop()
                self?.listenController.stop()
                NSApp.terminate(nil)
            }
        )
        listenController.onStateChange = { [weak self] listening in
            self?.statusItem.setListening(listening)
        }
        statusItem.acceptDrops { [weak self] urls in
            guard let self, let url = urls.first else { return }
            self.fileWindow.show()
            Task { await FileTranscriber.transcribe(url: url, into: self.fileModel) }
        }

        // First run, or any missing grant: open the setup assistant.
        // (Same test the assistant itself uses; the two must agree.)
        if !OnboardingView.allPermissionsGranted() {
            onboardingWindow.show()
        } else if !UserDefaults.standard.bool(forKey: "tourSeen") {
            // Fully set up but never toured: show "the moves" exactly once
            onboardingWindow.show()
        }
        UserDefaults.standard.set(true, forKey: "tourSeen")

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            if !granted {
                Log.info("notifications denied; failures will surface as sounds only")
            }
        }

        // The HUD only appears while talking; hide it if everything it can
        // show gets turned off mid-hold
        hudWatcher = ConfigStore.shared.$hudEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                if !enabled && !ConfigStore.shared.livePreview { self?.hud.hide() }
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
            self?.voiceActivity(level)
        }
        transcriber.onPartial = { [weak self] text in
            guard ConfigStore.shared.livePreview else { return }
            self?.hud.setText(text)
        }
        // AirPods (or any device) connecting mid-dictation: finish the
        // session gracefully with what was said instead of crashing on the
        // dead audio graph
        transcriber.onDeviceChange = { [weak self] in
            guard let self, self.busy else { return }
            Log.info("input device changed mid-session; finishing dictation")
            // fn may still be physically held; swallow that release so it
            // does not read as a new gesture. Hands-free holds no key.
            if !self.handsFree { self.ignoreNextRelease = true }
            self.endSession(cancelled: false)
        }
        fnMonitor.onEscape = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.handsFree else { return }
                self.cancelled = true
                self.endSession(cancelled: true)
            }
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

        StatsStore.shared.backfillIfNeeded(from: HistoryStore.shared.entries)

        Task {
            try? await transcriber.ensureModel()
            await Cleanup.warmUp()
            Log.info("yapping ready: hold the globe/fn key to talk")
        }
        UpdateCheck.startQuietChecks { [weak self] available in
            self?.statusItem.setUpdateAvailable(available)
        }
    }

    private func openMain(_ section: MainSection) {
        MainWindowState.shared.section = section
        mainWindow.show()
    }

    /// Silence auto-stop for hands-free sessions (opt-in): about 2.5s of
    /// quiet after at least 4s of recording ends the session.
    private func voiceActivity(_ level: Float) {
        DispatchQueue.main.async {
            guard self.handsFree, ConfigStore.shared.handsFreeAutoStop else { return }
            if level > 0.012 {
                self.lastVoiceAt = Date()
            } else if Date().timeIntervalSince(self.lastVoiceAt) > 2.5,
                      Date().timeIntervalSince(self.pressedAt) > 4 {
                self.endSession(cancelled: false)
            }
        }
    }

    /// "... send it" at the end of a dictation strips the phrase and asks
    /// for a Return press after pasting.
    static func stripSendCommand(from text: String) -> String? {
        let pattern = "[\\s,.!?]*send it[\\s.!?]*$"
        guard let range = text.range(
            of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let stripped = String(text[..<range.lowerBound])
        return stripped.isEmpty ? nil : stripped
    }

    private func pickAndTranscribeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileWindow.show()
        Task { await FileTranscriber.transcribe(url: url, into: fileModel) }
    }

    private func requestPermissions() {
        // Microphone prompt up front, not mid-first-dictation
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { Log.error("microphone permission denied") }
        }
        // Some SpeechAnalyzer paths still gate on this; harmless if not
        SFSpeechRecognizer.requestAuthorization { _ in }
        // Accessibility is needed to post the synthetic cmd-V
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Log.info("waiting for Accessibility permission (needed to paste)")
        }
    }

    private func fnPressed() {
        // Second tap within the grace window: upgrade the running session
        // to hands-free instead of discarding it
        if pendingTapTimer != nil {
            pendingTapTimer?.invalidate()
            pendingTapTimer = nil
            handsFree = true
            ignoreNextRelease = true
            lastVoiceAt = Date()
            statusItem.setState(.recording, detail: "hands-free")
            hud.setStyleChip("hands-free")
            Sound.play("Hero")
            return
        }
        // A tap while hands-free ends the session normally
        if handsFree {
            ignoreNextRelease = true
            endSession(cancelled: false)
            return
        }
        guard !busy else { return }

        // Password fields: refuse before the mic ever opens, so nothing is
        // recorded, nothing reaches the cleanup model, and nothing lands in
        // History. Two AX reads with a 0.1s timeout, which is well inside the
        // 0.35s minimum hold, so the gesture cannot feel it.
        // (If this ever does cost too much: start the mic and this check
        // concurrently in axSnapshot below, and abort the transcriber on a
        // secure result instead.)
        if SecureGuard.shouldBlock(AXContext.focusSecurity(),
                                   enabled: ConfigStore.shared.blockSecureFields) {
            Log.info("dictation refused: focused field reports itself secure")
            Sound.refused()
            Self.notify("Dictation blocked", body: SecureGuard.blockedNotice)
            return
        }

        busy = true
        cancelled = false
        pressedAt = Date()
        ActivationPolicy.sessionBegan()

        // Mic first, everything else after: every millisecond before the
        // engine starts is a millisecond of the user's first word at risk
        startTask = Task {
            do {
                try await transcriber.start()
                return true
            } catch {
                Log.error("could not start recording: \(error)")
                return false
            }
        }

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

        statusItem.setState(.recording, detail: activeStyle?.name)
        let config = ConfigStore.shared
        if config.hudEnabled || config.livePreview {
            hud.begin(
                style: activeStyle?.name, startedAt: pressedAt, maxHold: maxHold,
                showBars: config.hudEnabled, showText: config.livePreview)
        }
        Sound.play("Pop")

        maxTimer = Timer.scheduledTimer(withTimeInterval: maxHold, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.ignoreNextRelease = true
            self.endSession(cancelled: false)
        }
    }

    private func fnReleased() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard busy, !handsFree else { return }

        if Date().timeIntervalSince(pressedAt) < minHold {
            // Might be the first tap of a double-tap: keep recording for a
            // grace beat before discarding
            pendingTapTimer = Timer.scheduledTimer(
                withTimeInterval: 0.45, repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                self.pendingTapTimer = nil
                self.cancelled = true
                self.endSession(cancelled: true)
            }
            return
        }
        endSession(cancelled: cancelled)
    }

    /// Ends the current session (hold release, hands-free stop, Esc, or
    /// max-duration) and runs the pipeline unless cancelled.
    private func endSession(cancelled wasCancelled: Bool) {
        guard busy else { return }
        maxTimer?.invalidate()
        maxTimer = nil
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        handsFree = false

        if wasCancelled {
            hud.hide()
        } else {
            hud.setProcessing("transcribing...")
        }
        statusItem.setState(wasCancelled ? .idle : .processing)
        if !wasCancelled { Sound.play("Tink") }
        let heldFor = Date().timeIntervalSince(pressedAt)

        Task {
            defer {
                busy = false
                statusItem.setState(.idle)
                // After the paste and after any "send it" Return, so a policy
                // change can never precede text landing in the target app
                ActivationPolicy.sessionEnded()
            }
            let started = await startTask?.value ?? false
            guard started else {
                Sound.failed()
                await transcriber.abort()
                hud.hide()
                return
            }
            if wasCancelled {
                // A cancelled dictation that ran a long time is more likely
                // a slip than an intent to burn the words: transcribe it
                // quietly into History, never paste
                if heldFor > 30 {
                    let recovered = (try? await transcriber.stop()) ?? ""
                    // Never archive what a secure field would have received
                    let secure = SecureGuard.shouldBlock(
                        AXContext.focusSecurity(),
                        enabled: ConfigStore.shared.blockSecureFields)
                    if !recovered.isEmpty, !secure {
                        HistoryStore.shared.add(
                            raw: recovered, cleaned: recovered,
                            appName: self.targetApp?.localizedName ?? "Unknown")
                        StatsStore.shared.record(
                            words: StatsStore.wordCount(recovered), seconds: heldFor,
                            app: self.targetApp?.localizedName ?? "Unknown")
                        Self.notify(
                            "Dictation cancelled",
                            body: "It ran \(Int(heldFor))s, so the transcript was saved to History instead of being discarded.")
                    }
                } else {
                    await transcriber.abort()
                }
                return
            }
            do {
                let text = try await transcriber.stop()
                guard !text.isEmpty else {
                    Sound.failed()
                    hud.hide()
                    return
                }
                let (selection, fieldContext) = await self.axSnapshot?.value ?? (nil, nil)

                var output: String
                if let selection, !selection.isEmpty {
                    // Voice edit: the spoken words are an instruction applied
                    // to the selected text; pasting replaces the selection
                    self.statusItem.setState(.processing, detail: "Editing selection")
                    self.hud.setProcessing("editing selection...")
                    guard let edited = await Cleanup.rewrite(
                        selection: selection, instruction: text) else {
                        Sound.failed()
                        Self.notify("Edit failed",
                                    body: "Selection left unchanged. \(Cleanup.providerHint)")
                        self.hud.hide()
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
                guard !self.cancelled else {
                    self.hud.hide()
                    return
                }

                // Focus can move mid-session, so check again before the text
                // goes anywhere: not to the target app, not to the clipboard,
                // not to History or Stats.
                if SecureGuard.shouldBlock(AXContext.focusSecurity(),
                                           enabled: ConfigStore.shared.blockSecureFields) {
                    Log.info("paste refused: focus moved into a secure field")
                    Sound.refused()
                    Self.notify("Dictation discarded", body: SecureGuard.blockedNotice)
                    self.hud.hide()
                    return
                }

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
                let config = ConfigStore.shared

                // "send it" ends the dictation with a Return press
                var sendIt = false
                if config.sendCommand, !isEdit, self.activeStyle?.verbatim != true,
                   let stripped = Self.stripSendCommand(from: output) {
                    output = stripped
                    sendIt = true
                }

                let final = (isEdit || !config.trailingSpace) ? output : output + " "
                if config.copyInsteadOfPaste && !isEdit {
                    Paster.copyOnly(output)
                    Self.notify("Copied", body: "Your dictation is on the clipboard.")
                } else {
                    Paster.paste(final)
                    if sendIt {
                        try? await Task.sleep(for: .milliseconds(160))
                        Paster.pressReturn()
                    }
                }
                self.hud.finish()
                HistoryStore.shared.add(
                    raw: text, cleaned: output,
                    appName: self.targetApp?.localizedName ?? "Unknown")
                StatsStore.shared.record(
                    words: StatsStore.wordCount(output), seconds: heldFor,
                    app: self.targetApp?.localizedName ?? "Unknown")
                self.offerTips()
            } catch {
                Log.error("dictation error: \(error)")
                Sound.failed()
                Self.notify("Dictation failed", body: "\(error.localizedDescription)")
                self.hud.hide()
            }
        }
    }

    /// At most three one-time tips, tied to real usage, never repeated.
    /// Not nagging users is part of the brand.
    private func offerTips() {
        let d = UserDefaults.standard
        let count = d.integer(forKey: "tipSessionCount") + 1
        d.set(count, forKey: "tipSessionCount")
        if count == 10 {
            Self.notify("Did you know?",
                        body: "Select any text, hold the globe key, and speak an instruction. Yapping rewrites the selection.")
        } else if count == 25 {
            Self.notify("Did you know?",
                        body: "End a dictation with \"send it\" and the message goes out with zero keypresses.")
        }
        if activeStyle == nil, !d.bool(forKey: "tipStyles"),
           let bundleID = targetApp?.bundleIdentifier?.lowercased(),
           ["slack", "discord", "messages", "telegram", "whatsapp", "teams"]
               .contains(where: { bundleID.contains($0) }) {
            let chats = d.integer(forKey: "tipChatCount") + 1
            d.set(chats, forKey: "tipChatCount")
            if chats == 3 {
                d.set(true, forKey: "tipStyles")
                Self.notify("Did you know?",
                            body: "Styles adapt your writing per app. Give this one a casual voice in Settings > Styles.")
            }
        }
    }

    /// A Dock icon exists while a window is open, so clicking it should
    /// bring the app back rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMain(.dictations) }
        return true
    }

    /// Closing the last window returns yapping to the menu bar; it must not
    /// quit. The default is already false, but a policy-switching app should
    /// not leave that to inference.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

    /// Something went wrong.
    static func failed() { play("Basso") }

    /// Nothing went wrong; yapping declined on purpose. Distinct from a
    /// failure so a blocked password field never sounds like a bug.
    static func refused() { play("Submarine") }
}
