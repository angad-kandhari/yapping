import AppKit
import SwiftUI

/// Shared model for long-form transcription (file jobs and Listen mode).
final class TranscriptModel: ObservableObject {
    @Published var title = ""
    @Published var finalized = ""
    @Published var volatileTail = ""
    @Published var progress: Double?  // file mode only
    @Published var running = false
    @Published var statusLine = ""
    @Published var failure: String?

    var isEmpty: Bool { finalized.isEmpty && volatileTail.isEmpty }

    func reset(title: String) {
        self.title = title
        finalized = ""
        volatileTail = ""
        progress = nil
        running = false
        statusLine = ""
        failure = nil
    }
}

/// The transcript window: live-growing text (volatile tail dimmed),
/// progress for file jobs, copy and save controls.
struct TranscriptView: View {
    @ObservedObject var model: TranscriptModel
    var onStop: (() -> Void)?

    var body: some View {
        BrandChrome(title: "transcript") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(model.title).font(.headline)
                    if model.running {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if model.running, let onStop {
                        Button("Stop") { onStop() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                if let progress = model.progress {
                    ProgressView(value: progress)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                if let failure = model.failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        (Text(model.finalized)
                            + Text(model.volatileTail).foregroundColor(.secondary))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .id("transcript")
                    }
                    .onChange(of: model.finalized) { _, _ in
                        proxy.scrollTo("transcript", anchor: .bottom)
                    }
                }

                Divider()

                HStack {
                    Text(model.statusLine)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.finalized, forType: .string)
                    }
                    .disabled(model.isEmpty)
                    Button("Save as...") { save() }
                        .disabled(model.isEmpty)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.title
            .replacingOccurrences(of: " ", with: "-")
            .lowercased() + "-transcript.txt"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? model.finalized.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
