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

    init(id: UUID, date: Date, kind: Kind, title: String, seconds: Double,
         words: Int, text: String, summary: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.seconds = seconds
        self.words = words
        self.text = text
        self.summary = summary
    }

    /// Tolerant decoding, adopted before this store needs new fields so the
    /// next addition is free rather than destructive.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .file
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Transcript"
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}

/// The transcripts library: every completed Listen session and file job,
/// kept so they outlive their windows. Capped at 100 entries; private
/// like everything else (owner-only file permissions).
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()
    @Published private(set) var entries: [TranscriptEntry] = []

    private let file = Store.directory.appendingPathComponent("transcripts.json")

    private init() {
        entries = Store.load([TranscriptEntry].self, from: file, label: "transcripts") ?? []
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
        Store.save(entries, to: file, label: "transcripts")
    }
}
