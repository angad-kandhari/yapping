import Foundation

/// Disk persistence for every local store, with one rule: a file we cannot
/// read is never silently discarded. Before 2.5 a single unreadable byte
/// dropped an entire history, and the user was never told. Now the bytes are
/// copied aside and the failure is logged.
enum Store {
    /// Tests point this at a temp directory so a rescue never writes into
    /// the real library.
    static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yapping")
    }

    private static var rescueDirectory: URL {
        directory.appendingPathComponent("rescued")
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Decode a store file. Returns nil for "no file yet" and for "file was
    /// unreadable", but the second case leaves a rescue copy and a log line.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, label: String) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            rescue(data: data, label: label, error: error)
            return nil
        }
    }

    /// Same contract for the JSON blobs kept in UserDefaults (styles,
    /// replacements, snippets). Losing a user's hand-written prompts to a
    /// silent decode failure is the worst version of this bug.
    static func loadDefaults<T: Decodable>(
        _ type: T.Type, key: String, label: String
    ) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            rescue(data: data, label: label, error: error)
            return nil
        }
    }

    /// Atomic write plus owner-only permissions. Atomic because a crash
    /// mid-write used to truncate the file, which the next launch then read
    /// as corruption.
    static func save<T: Encodable>(_ value: T, to url: URL, label: String) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error("store write failed for \(label): \(error)")
        }
    }

    /// Keep the bytes we could not read, newest three per store.
    private static func rescue(data: Data, label: String, error: Error) {
        let fm = FileManager.default
        try? fm.createDirectory(at: rescueDirectory, withIntermediateDirectories: true)
        let name = "\(label)-\(stamp.string(from: Date())).json"
        let target = rescueDirectory.appendingPathComponent(name)
        try? data.write(to: target, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        Log.error("store rescue: \(label) could not be read (\(error)); the bytes are in \(target.path) and the app is starting that store fresh")
        prune(label: label)
    }

    private static func prune(label: String, keep: Int = 3) {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(
            at: rescueDirectory, includingPropertiesForKeys: nil) else { return }
        let mine = all
            .filter { $0.lastPathComponent.hasPrefix("\(label)-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in mine.dropFirst(keep) {
            try? fm.removeItem(at: old)
        }
    }
}
