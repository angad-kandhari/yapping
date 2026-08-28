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
    @Published var summary = ""
    @Published var summarizing = false
    /// Set once the finished session lands in the transcripts library, so
    /// later summaries update the stored copy too.
    var storeID: UUID?

    var isEmpty: Bool { finalized.isEmpty && volatileTail.isEmpty }

    func reset(title: String) {
        self.title = title
        finalized = ""
        volatileTail = ""
        progress = nil
        running = false
        statusLine = ""
        failure = nil
        summary = ""
        summarizing = false
        storeID = nil
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

                if !model.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Notes").font(.caption.bold())
                                .foregroundStyle(Brand.accent)
                            Spacer()
                            Button("Copy notes") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.summary, forType: .string)
                            }
                            .controlSize(.small)
                        }
                        Text(model.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.4))
                    Divider()
                }

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
                    if model.summarizing {
                        ProgressView().controlSize(.small)
                    }
                    Button(model.summary.isEmpty ? "Summarize" : "Summarize Again") {
                        summarize()
                    }
                    .disabled(model.isEmpty || model.running || model.summarizing)
                    Button("Copy") {
                        // Same document Save writes: notes above transcript
                        let contents = model.summary.isEmpty
                            ? model.finalized
                            : model.summary + "\n\n---\n\n" + model.finalized
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(contents, forType: .string)
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

    private func summarize() {
        model.summarizing = true
        let transcript = model.finalized
        Task {
            let notes = await Cleanup.summarize(transcript)
            await MainActor.run {
                model.summarizing = false
                if let notes {
                    model.summary = notes
                    if let id = model.storeID {
                        TranscriptStore.shared.updateSummary(id: id, summary: notes)
                    }
                } else {
                    model.failure = "Could not summarize. Is your cleanup provider (Settings > Cleanup) available?"
                }
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.title
            .replacingOccurrences(of: " ", with: "-")
            .lowercased() + "-transcript.txt"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            let contents = model.summary.isEmpty
                ? model.finalized
                : model.summary + "\n\n---\n\n" + model.finalized
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // A failed save with no dialog looks identical to a
                // successful one until the file is missing later
                Log.error("transcript save failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "Could not save the transcript"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
