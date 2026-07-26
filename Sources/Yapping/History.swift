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

/// Last 20 dictations, raw and cleaned side by side. This is the
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
            if self.entries.count > 20 {
                self.entries.removeLast(self.entries.count - 20)
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

    var body: some View {
        Group {
            if store.entries.isEmpty {
                Text("No dictations yet. Hold the globe key and yap.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.entries) { entry in
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
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .toolbar {
            Button("Clear") { store.clear() }
        }
    }
}
