import Foundation
import SwiftUI
import AppKit

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let appName: String
    let raw: String
    let cleaned: String
}

/// Recent dictations, raw and cleaned side by side. This is the
/// transparency feature: cleanup is inspectable, never a black box.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []

    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yapping/history.json")

    private init() {
        if let data = try? Data(contentsOf: file),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = loaded
        }
    }

    func add(raw: String, cleaned: String, appName: String) {
        DispatchQueue.main.async {
            self.entries.insert(
                HistoryEntry(id: UUID(), date: Date(), appName: appName,
                             raw: raw, cleaned: cleaned),
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
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file)
            // dictations are private
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    @State private var query = ""

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
        BrandChrome(title: "history") {
            historyContent
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                Text("No dictations yet. Hold the globe key and yap.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
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
                Button("Clear history") { store.clear() }
                    .disabled(store.entries.isEmpty)
            }
            .padding(12)
        }
    }
}
