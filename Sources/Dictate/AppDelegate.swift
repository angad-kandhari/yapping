import AppKit
import AVFoundation
import ApplicationServices
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fnMonitor = FnKeyMonitor()
    private let transcriber = Transcriber()
    private var statusItem: StatusItem!

    private var busy = false
    private var cancelled = false
    private var pressedAt = Date.distantPast
    private var startTask: Task<Bool, Never>?
    private var maxTimer: Timer?

    /// Holds shorter than this are accidental taps; discard them.
    private let minHold: TimeInterval = 0.35
    /// Safety stop for a stuck key.
    private let maxHold: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItem(onQuit: { [weak self] in
            self?.fnMonitor.stop()
            NSApp.terminate(nil)
        })
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
            NSLog("dictate ready: hold the globe/fn key to talk")
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
                let cleaned = await Cleanup.polish(text)
                guard !self.cancelled else { return }
                // Trailing space so consecutive dictations don't run together
                Paster.paste(cleaned + " ")
            } catch {
                NSLog("dictation error: \(error)")
                Sound.play("Basso")
            }
        }
    }
}

enum Sound {
    static func play(_ name: String) {
        NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)?.play()
    }
}
