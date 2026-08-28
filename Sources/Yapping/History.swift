import Foundation
import SwiftUI
import AppKit

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let appName: String
    let raw: String
    let cleaned: String
    /// The style in force when this was dictated, for stats and for
    /// re-running cleanup later. Absent on entries written before 2.5.
    var styleName: String?

    init(id: UUID, date: Date, appName: String, raw: String, cleaned: String,
         styleName: String? = nil) {
        self.id = id
        self.date = date
        self.appName = appName
        self.raw = raw
        self.cleaned = cleaned
        self.styleName = styleName
    }

    /// Tolerant of anything an older build wrote; only id and date are
    /// required, and both have always been present.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? "Unknown"
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
        cleaned = try c.decodeIfPresent(String.self, forKey: .cleaned) ?? ""
        styleName = try c.decodeIfPresent(String.self, forKey: .styleName)
    }
}

/// Recent dictations, raw and cleaned side by side. This is the
/// transparency feature: cleanup is inspectable, never a black box.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []

    private let file = Store.directory.appendingPathComponent("history.json")

    private init() {
        entries = Store.load([HistoryEntry].self, from: file, label: "history") ?? []
    }

    func add(raw: String, cleaned: String, appName: String, styleName: String? = nil) {
        DispatchQueue.main.async {
            self.entries.insert(
                HistoryEntry(id: UUID(), date: Date(), appName: appName,
                             raw: raw, cleaned: cleaned, styleName: styleName),
                at: 0)
            if self.entries.count > 200 {
                self.entries.removeLast(self.entries.count - 200)
            }
            self.save()
        }
    }

    func remove(id: UUID) {
        DispatchQueue.main.async {
            self.entries.removeAll { $0.id == id }
            self.save()
        }
    }

    /// Re-running cleanup writes the new text back over the old one; the raw
    /// transcript is never touched, so this stays reversible in spirit.
    func replace(id: UUID, cleaned: String) {
        DispatchQueue.main.async {
            guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
            let old = self.entries[index]
            self.entries[index] = HistoryEntry(
                id: old.id, date: old.date, appName: old.appName,
                raw: old.raw, cleaned: cleaned, styleName: old.styleName)
            self.save()
        }
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        // dictations are private; Store handles atomicity and 0600
        Store.save(entries, to: file, label: "history")
    }
}

struct DictationsPane: View {
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject var config = ConfigStore.shared
    @State private var query = ""
    @State private var confirmClear = false
    @State private var rerunning: UUID?
    @State private var showingDiff: Set<UUID> = []
    @State private var selected: Set<UUID> = []

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.cleaned.localizedCaseInsensitiveContains(q)
                || $0.raw.localizedCaseInsensitiveContains(q)
                || $0.appName.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "dictations",
                       sub: "every dictation, raw and cleaned, side by side")
                .padding(.horizontal, 36)
                .padding(.top, 48)
            historyContent
        }
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                Text("No dictations yet. Hold the globe key and yap.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .padding(.horizontal, 36)
                    .padding(.bottom, 8)
                if filtered.isEmpty {
                    Text("Nothing matches \"\(query)\".")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, selection: $selected) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.date, style: .time)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(entry.appName)
                                    .font(.caption).foregroundStyle(.secondary)
                                if let style = entry.styleName {
                                    Text(style)
                                        .font(.caption2)
                                        .foregroundStyle(Brand.accent)
                                }
                                Spacer()
                                if rerunning == entry.id {
                                    ProgressView().controlSize(.small)
                                }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.cleaned, forType: .string)
                                }
                            }
                            Text(entry.cleaned)
                            if entry.raw != entry.cleaned, !entry.raw.isEmpty {
                                changes(for: entry)
                            }
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Copy raw transcript") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.raw, forType: .string)
                            }
                            Menu("Re-run cleanup with") {
                                Button("No style") { rerun(entry, style: nil) }
                                ForEach(config.styles) { style in
                                    Button(style.name) { rerun(entry, style: style) }
                                }
                            }
                            .disabled(entry.raw.isEmpty)
                            Divider()
                            Button("Delete", role: .destructive) { store.remove(id: entry.id) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    // The context menu should not be the only per-row
                    // delete; the Delete key is the expected gesture
                    .onDeleteCommand {
                        selected.forEach { store.remove(id: $0) }
                        selected.removeAll()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if !store.entries.isEmpty {
                    Text("\(filtered.count) of \(store.entries.count)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Menu("Export") {
                    Button("Markdown...") { export(.markdown) }
                    Button("JSON...") { export(.json) }
                }
                .fixedSize()
                .disabled(store.entries.isEmpty)
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .disabled(store.entries.isEmpty)
                    .confirmationDialog(
                        "Delete all \(store.entries.count) dictations? This cannot be undone.",
                        isPresented: $confirmClear, titleVisibility: .visible
                    ) {
                        Button("Clear History", role: .destructive) { store.clear() }
                    }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Corrections

    /// The raw transcript stays visible by default, because "raw and cleaned,
    /// side by side" is the promise this pane makes. The toggle swaps it for
    /// a word-level diff, which answers the more useful question: what did
    /// cleanup actually change?
    @ViewBuilder
    private func changes(for entry: HistoryEntry) -> some View {
        let spans = TextDiff.words(from: entry.raw, to: entry.cleaned)
        let showing = showingDiff.contains(entry.id)
        HStack(spacing: 8) {
            if let spans {
                let count = TextDiff.corrections(spans)
                Text(count == 1 ? "1 correction" : "\(count) corrections")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Button(showing ? "Show raw" : "Show what changed") {
                if showing {
                    showingDiff.remove(entry.id)
                } else {
                    showingDiff.insert(entry.id)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        if showing, let spans {
            diffText(spans)
                .font(.callout)
                .textSelection(.enabled)
        } else {
            Text("Raw: \(entry.raw)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Struck through for what was said, accent for what was pasted instead.
    private func diffText(_ spans: [TextDiff.Span]) -> Text {
        spans.reduce(Text(verbatim: "")) { out, span in
            let piece = Text(verbatim: span.text + " ")
            switch span.kind {
            case .same:
                return out + piece.foregroundStyle(.secondary)
            case .removed:
                return out + piece.strikethrough().foregroundStyle(.tertiary)
            case .added:
                return out + piece.foregroundStyle(Brand.accent)
            }
        }
    }

    // MARK: - Actions

    /// Re-run cleanup over the original transcript. The raw text is kept, so
    /// a style that makes things worse can simply be run again.
    private func rerun(_ entry: HistoryEntry, style: Style?) {
        rerunning = entry.id
        Task {
            let cleaned = await Cleanup.polish(text: entry.raw, style: style)
            await MainActor.run {
                store.replace(id: entry.id, cleaned: cleaned)
                rerunning = nil
            }
        }
    }

    private enum ExportFormat { case markdown, json }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format == .markdown
            ? "yapping-dictations.md" : "yapping-dictations.json"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let entries = filtered
        do {
            switch format {
            case .markdown:
                try HistoryExport.markdown(entries).write(to: url, atomically: true, encoding: .utf8)
            case .json:
                try HistoryExport.json(entries).write(to: url, options: .atomic)
            }
        } catch {
            Log.error("history export failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Could not export dictations"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// Serializers kept pure so they can be tested without a save panel.
enum HistoryExport {
    static func markdown(_ entries: [HistoryEntry]) -> String {
        var out = ["# yapping dictations", ""]
        for entry in entries {
            out.append("## \(entry.date.formatted(date: .abbreviated, time: .shortened)) \u{00B7} \(entry.appName)")
            if let style = entry.styleName {
                out.append("_style: \(style)_")
            }
            out.append("")
            out.append(entry.cleaned)
            if entry.raw != entry.cleaned, !entry.raw.isEmpty {
                out.append("")
                out.append("> raw: \(entry.raw)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static func json(_ entries: [HistoryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }
}
