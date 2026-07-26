import AVFoundation
import AppKit
import ApplicationServices
import SwiftUI

/// First-run setup assistant: live status for every permission and setting
/// Yapping needs, each with a button that jumps to the right place.
/// Shown automatically until everything is green.
struct OnboardingView: View {
    @State private var mic = false
    @State private var inputMonitoring = false
    @State private var accessibility = false
    @State private var globeKeyFree = false
    @State private var ollama = false
    @State private var timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var allRequiredGreen: Bool { mic && inputMonitoring && accessibility && globeKeyFree }

    var body: some View {
        BrandChrome(title: "setup") {
            checklist
        }
        .frame(width: 500)
    }

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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.circle")
                    .foregroundStyle(.secondary).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System audio (optional)").bold()
                    Text("Listen mode asks for System Audio Recording Only the first time you use it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if allRequiredGreen {
                Label("Ready. Hold the globe key and yap.", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
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

    private static func globeKeyDoesNothing() -> Bool {
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
