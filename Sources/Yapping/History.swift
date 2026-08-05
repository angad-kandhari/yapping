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
    @State private var query = ""
    @State private var confirmClear = false

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
                    List(filtered) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.date, style: .time)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(entry.appName)
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.cleaned, forType: .string)
                                }
                            }
                            Text(entry.cleaned)
                            if entry.raw != entry.cleaned {
                                Text("Raw: \(entry.raw)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollContentBackground(.hidden)
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
}
