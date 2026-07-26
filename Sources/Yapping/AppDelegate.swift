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

    private var busy = false
    private var cancelled = false
    private var pressedAt = Date.distantPast
    private var startTask: Task<Bool, Never>?
    private var maxTimer: Timer?
    private var targetApp: NSRunningApplication?
    private var localeWatcher: AnyCancellable?

    /// Holds shorter than this are accidental taps; discard them.
    private let minHold: TimeInterval = 0.35
    /// Safety stop for a stuck key.
    private let maxHold: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItem(
            onSettings: { [weak self] in self?.settingsWindow.show() },
            onHistory: { [weak self] in self?.historyWindow.show() },
            onQuit: { [weak self] in
                self?.fnMonitor.stop()
                NSApp.terminate(nil)
            }
        )

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // Language switches trigger a one-time model download for that locale
        localeWatcher = ConfigStore.shared.$localeID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { try? await self?.transcriber.ensureModel() }
            }
        transcriber.onLevel = { [weak self] level in
            self?.statusItem.pushLevel(level)
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
        statusItem.setState(.recording)
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
        statusItem.setState(wasCancelled ? .idle : .processing)
        if !wasCancelled { Sound.play("Tink") }

        Task {
            defer {
                busy = false
                statusItem.setState(.idle)
            }
            let started = await startTask?.value ?? false
            guard started else {
                Sound.play("Basso")
                await transcriber.abort()
                return
            }
            if wasCancelled {
                await transcriber.abort()
                return
            }
            do {
                let text = try await transcriber.stop()
                guard !text.isEmpty else {
                    Sound.play("Basso")
                    return
                }
                var cleaned = await Cleanup.polish(text)
                cleaned = ConfigStore.shared.applyTextRules(to: cleaned)
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
                Paster.paste(cleaned + " ")
                HistoryStore.shared.add(
                    raw: text, cleaned: cleaned,
                    appName: self.targetApp?.localizedName ?? "Unknown")
            } catch {
                NSLog("dictation error: \(error)")
                Sound.play("Basso")
                Self.notify("Dictation failed", body: "\(error.localizedDescription)")
            }
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
