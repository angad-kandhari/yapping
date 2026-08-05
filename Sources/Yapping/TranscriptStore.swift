import Foundation

struct TranscriptEntry: Codable, Identifiable {
    enum Kind: String, Codable { case listen, file }

    let id: UUID
    let date: Date
    let kind: Kind
    var title: String
    var seconds: Double
    var words: Int
    var text: String
    var summary: String
}

/// The transcripts library: every completed Listen session and file job,
/// kept so they outlive their windows. Capped at 100 entries; private
/// like everything else (owner-only file permissions).
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()
    @Published private(set) var entries: [TranscriptEntry] = []

    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yapping/transcripts.json")

    private init() {
        if let data = try? Data(contentsOf: file),
           let loaded = try? JSONDecoder().decode([TranscriptEntry].self, from: data) {
            entries = loaded
        }
    }

    @discardableResult
    func add(kind: TranscriptEntry.Kind, title: String, seconds: Double,
             words: Int, text: String, summary: String = "") -> UUID {
        let entry = TranscriptEntry(
            id: UUID(), date: Date(), kind: kind, title: title,
            seconds: seconds, words: words, text: text, summary: summary)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > 100 {
                self.entries.removeLast(self.entries.count - 100)
            }
            self.save()
        }
        return entry.id
    }

    func updateSummary(id: UUID, summary: String) {
        DispatchQueue.main.async {
            guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
            self.entries[index].summary = summary
            self.save()
        }
    }

    func remove(id: UUID) {
        DispatchQueue.main.async {
            self.entries.removeAll { $0.id == id }
            self.save()
        }
    }

    private func save() {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
