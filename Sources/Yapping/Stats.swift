import Foundation

struct DayStat: Codable, Equatable {
    var words = 0
    var sessions = 0
    var seconds = 0.0
}

struct AppStat: Codable, Equatable {
    var words = 0
    var sessions = 0
}

struct StatsData: Codable {
    var totalWords = 0
    var totalSessions = 0
    var totalSeconds = 0.0  // time actually spent speaking
    var days: [String: DayStat] = [:]  // "2026-08-05" keys
    var apps: [String: AppStat] = [:]  // app display-name keys
    var since = Date()
    var version = 1
}

/// Aggregate-forever dictation stats: numbers only, never text, so the
/// file stays a few KB after years and there is nothing sensitive in it.
/// Ships silently in 1.6 so the 1.7 dashboard is alive on day one.
final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    @Published private(set) var data = StatsData()

    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yapping/stats.json")

    /// Fixed-format day keys: DST and locale can never split a day in two.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private init() {
        if let raw = try? Data(contentsOf: file),
           let loaded = try? JSONDecoder().decode(StatsData.self, from: raw) {
            data = loaded
        }
    }

    func record(words: Int, seconds: TimeInterval, app: String, date: Date = Date()) {
        guard words > 0 else { return }
        DispatchQueue.main.async {
            var d = self.data
            d.totalWords += words
            d.totalSessions += 1
            d.totalSeconds += seconds
            let key = Self.dayKey(date)
            var day = d.days[key] ?? DayStat()
            day.words += words
            day.sessions += 1
            day.seconds += seconds
            d.days[key] = day
            var appStat = d.apps[app] ?? AppStat()
            appStat.words += words
            appStat.sessions += 1
            d.apps[app] = appStat
            // Apps churn (renames, one-offs); keep the 50 biggest
            if d.apps.count > 50,
               let smallest = d.apps.min(by: { $0.value.words < $1.value.words }) {
                d.apps.removeValue(forKey: smallest.key)
            }
            self.data = d
            self.save()
        }
    }

    /// One-time seed from existing history (word counts and dates only;
    /// no durations were recorded back then, so those days carry words
    /// but do not distort WPM).
    func backfillIfNeeded(from entries: [HistoryEntry]) {
        let seededKey = "statsSeeded"
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        for entry in entries {
            record(words: Self.wordCount(entry.cleaned), seconds: 0,
                   app: entry.appName, date: entry.date)
        }
        Log.info("stats: backfilled \(entries.count) history entries")
    }

    // MARK: - Pure math (unit-tested)

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Speaking pace. Only meaningful once real speaking time accrues;
    /// backfilled days contribute words but zero seconds.
    static func wpm(words: Int, seconds: Double) -> Double {
        guard seconds >= 60 else { return 0 }
        return Double(words) / (seconds / 60)
    }

    /// Minutes not spent typing, against a stated 40 WPM typing baseline.
    static func minutesSaved(words: Int, seconds: Double, typingWPM: Double = 40) -> Double {
        let typing = Double(words) / typingWPM
        let speaking = seconds / 60
        return max(0, typing - speaking)
    }

    static func streaks(dayKeys: Set<String>, today: Date = Date()) -> (current: Int, longest: Int) {
        let calendar = Calendar.current
        var current = 0
        var cursor = today
        // A streak survives until a full day is missed: count from today,
        // or from yesterday if today has no dictation yet
        if !dayKeys.contains(dayKey(cursor)),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        while dayKeys.contains(dayKey(cursor)),
              let previous = calendar.date(byAdding: .day, value: -1, to: cursor) {
            current += 1
            cursor = previous
        }

        let dates = dayKeys.compactMap { dayFormatter.date(from: $0) }.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for date in dates {
            if let p = previous,
               let next = calendar.date(byAdding: .day, value: 1, to: p),
               calendar.isDate(next, inSameDayAs: date) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return (current, longest)
    }

    private func save() {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: file)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
