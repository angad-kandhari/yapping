import AVFoundation
import AppKit
import ApplicationServices
import SwiftUI

/// The setup assistant, in two pages: the permissions checklist (live
/// status, one button each), then "the moves", a tour of the six features
/// nobody would otherwise discover. Shown automatically until everything
/// is green; the tour shows itself exactly once to ready users.
struct OnboardingView: View {
    var startOnTour = false

    @State private var page = 0
    @State private var mic = false
    @State private var inputMonitoring = false
    @State private var accessibility = false
    @State private var globeKeyFree = false
    @State private var ollama = false
    @State private var timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var allRequiredGreen: Bool { mic && inputMonitoring && accessibility && globeKeyFree }

    /// The same test AppDelegate uses to decide whether to auto-open this
    /// window; keep the two in agreement.
    static func allPermissionsGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && CGPreflightListenEventAccess()
            && AXIsProcessTrusted()
            && globeKeyDoesNothing()
    }

    var body: some View {
        BrandChrome(title: "setup") {
            if page == 0 { checklist } else { tour }
        }
        .frame(width: 500)
        .onAppear { if startOnTour { page = 1 } }
    }

    // MARK: - Page 1: permissions

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Welcome to yapping").font(.title2.bold())
                    Text("Four quick grants and you never touch this again.")
                        .foregroundStyle(.secondary)
                }
            }

            checkRow("Microphone", ok: mic,
                     detail: "So it can hear you.",
                     action: { openPane("Privacy_Microphone") })
            checkRow("Input Monitoring", ok: inputMonitoring,
                     detail: "So it can feel the globe key. Relaunch after granting.",
                     action: { openPane("Privacy_ListenEvent") })
            checkRow("Accessibility", ok: accessibility,
                     detail: "So it can type where your cursor is.",
                     action: { openPane("Privacy_Accessibility") })
            checkRow("Globe key set to Do Nothing", ok: globeKeyFree,
                     detail: "System Settings > Keyboard > \"Press globe key to\".",
                     action: { openPane(nil, keyboard: true) })
            checkRow("Ollama with a model (optional)", ok: ollama,
                     detail: "For filler-word cleanup. Without it, raw transcripts are pasted.",
                     action: { NSWorkspace.shared.open(URL(string: "https://ollama.com")!) })
            infoRow("System audio (optional)",
                    detail: "Listen mode asks for System Audio Recording Only the first time you use it.")

            HStack {
                if allRequiredGreen {
                    Label("Ready.", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Learn the moves") { page = 1 }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func checkRow(
        _ title: String, ok: Bool, detail: String, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button("Open", action: action)
            }
        }
    }

    private func infoRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Page 2: the moves

    private var tour: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("The moves").font(.title2.bold())
                    Text("Six ways to yap. No manual needed.")
                        .foregroundStyle(.secondary)
                }
            }

            move("globe", "Hold and talk",
                 "Hold the globe key, speak, release. Your words land at the cursor, cleaned up.")
            move("hand.tap", "Double-tap for hands-free",
                 "Tap the globe key twice to talk without holding. Tap again or press Esc to finish.")
            move("text.cursor", "Edit by voice",
                 "Select any text, hold the globe key, and speak an instruction. The selection is rewritten.")
            move("paperplane", "Say \"send it\"",
                 "End a dictation with \"send it\" and Return is pressed for you.")
            move("doc.badge.arrow.up", "Drop a file on the menu bar icon",
                 "Any audio or video becomes a transcript, faster than real time.")
            move("paintbrush", "Styles follow the app",
                 "Chat stays casual, email stays sharp, code stays verbatim. Tune them in Settings > Styles.")

            HStack {
                Button("Permissions") { page = 0 }
                Spacer()
                Text("Take this tour anytime: menu > Setup Assistant")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { NSApp.keyWindow?.performClose(nil) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func move(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Brand.accent)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Checks

    private func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        inputMonitoring = CGPreflightListenEventAccess()
        accessibility = AXIsProcessTrusted()
        globeKeyFree = Self.globeKeyDoesNothing()
        Task {
            let up = await Cleanup.reachable()
            await MainActor.run { ollama = up }
        }
    }

    static func globeKeyDoesNothing() -> Bool {
        CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString
        ) as? Int == 0
    }

    private func openPane(_ pane: String?, keyboard: Bool = false) {
        let url = keyboard
            ? "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
            : "x-apple.systempreferences:com.apple.preference.security?\(pane ?? "")"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
