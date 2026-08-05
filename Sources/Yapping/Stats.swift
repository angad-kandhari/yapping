import Foundation

struct DayStat: Codable, Equatable {
    var words = 0
    var sessions = 0
    var seconds = 0.0
    /// Words per hour of the day, keyed "00" to "23". String keys because
    /// Swift encodes integer-keyed dictionaries as a flat array, which is
    /// unreadable on disk and a migration hazard. Empty before 2.5.
    var hours: [String: Int] = [:]

    init(words: Int = 0, sessions: Int = 0, seconds: Double = 0, hours: [String: Int] = [:]) {
        self.words = words
        self.sessions = sessions
        self.seconds = seconds
        self.hours = hours
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        hours = try c.decodeIfPresent([String: Int].self, forKey: .hours) ?? [:]
    }
}

struct AppStat: Codable, Equatable {
    var words = 0
    var sessions = 0

    init(words: Int = 0, sessions: Int = 0) {
        self.words = words
        self.sessions = sessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
    }
}

struct StatsData: Codable {
    static let currentVersion = 2

    var totalWords = 0
    var totalSessions = 0
    var totalSeconds = 0.0  // time actually spent speaking
    var days: [String: DayStat] = [:]  // "2026-08-05" keys
    var apps: [String: AppStat] = [:]  // app display-name keys
    /// Per-style usage, the one dimension the product story is built on and
    /// the only one that went unmeasured until 2.5.
    var styles: [String: AppStat] = [:]
    var since = Date()
    var version = 1

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalWords = try c.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
        totalSessions = try c.decodeIfPresent(Int.self, forKey: .totalSessions) ?? 0
        totalSeconds = try c.decodeIfPresent(Double.self, forKey: .totalSeconds) ?? 0
        days = try c.decodeIfPresent([String: DayStat].self, forKey: .days) ?? [:]
        apps = try c.decodeIfPresent([String: AppStat].self, forKey: .apps) ?? [:]
        styles = try c.decodeIfPresent([String: AppStat].self, forKey: .styles) ?? [:]
        // A v1 file has no `since`. Defaulting to now would read "member
        // since today" forever, so leave it nil-ish and let migration repair
        // it from the earliest day key.
        since = try c.decodeIfPresent(Date.self, forKey: .since) ?? .distantFuture
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
}

/// Pure, testable schema migration. Runs once, logs once, saves once.
enum StatsMigration {
    static func migrate(_ data: StatsData, fileCreated: Date? = nil) -> (StatsData, note: String?) {
        var out = data
        var notes: [String] = []

        // Repair `since`: earliest recorded day, the file's own creation
        // date, or today, whichever is earliest and real.
        if out.since == .distantFuture || out.since > Date() {
            let earliestDay = out.days.keys.sorted().first
                .flatMap { StatsStore.dayFormatter.date(from: $0) }
            let candidates = [earliestDay, fileCreated, Date()].compactMap { $0 }
            out.since = candidates.min() ?? Date()
            notes.append("repaired the member-since date")
        }

        if out.version < 2 {
            notes.append("added hour and style buckets")
            out.version = StatsData.currentVersion
        }

        return (out, notes.isEmpty ? nil : notes.joined(separator: ", "))
    }
}

/// Aggregate-forever dictation stats: numbers only, never text, so the
/// file stays a few KB after years and there is nothing sensitive in it.
/// Ships silently in 1.6 so the 1.7 dashboard is alive on day one.
final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    @Published private(set) var data = StatsData()

    private let file = Store.directory.appendingPathComponent("stats.json")

    /// Fixed-format day keys: DST and locale can never split a day in two.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Hour buckets use the same fixed-format discipline as day keys.
    static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private init() {
        guard var loaded = Store.load(StatsData.self, from: file, label: "stats") else { return }

        // A file from a newer build is kept, not dropped; JSONDecoder has
        // already ignored whatever it did not recognise, so warn that those
        // fields will be lost the next time we write.
        if loaded.version > StatsData.currentVersion {
            Log.info("stats.json is version \(loaded.version), newer than \(StatsData.currentVersion); unknown fields will be dropped on the next write")
            data = loaded
            return
        }

        let created = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.creationDate] as? Date
        let (migrated, note) = StatsMigration.migrate(loaded, fileCreated: created)
        loaded = migrated
        data = loaded
        if let note {
            Log.info("stats: migrated to version \(StatsData.currentVersion) (\(note))")
            save()
        }
    }

    func record(words: Int, seconds: TimeInterval, app: String,
                style: String? = nil, date: Date = Date()) {
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
            day.hours[Self.hourKey(date), default: 0] += words
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
            var styleStat = d.styles[style ?? "No style"] ?? AppStat()
            styleStat.words += words
            styleStat.sessions += 1
            d.styles[style ?? "No style"] = styleStat
            if d.styles.count > 30,
               let smallest = d.styles.min(by: { $0.value.words < $1.value.words }) {
                d.styles.removeValue(forKey: smallest.key)
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

    static func hourKey(_ date: Date) -> String {
        hourFormatter.string(from: date)
    }

    /// Words per hour of day across every recorded day, index 0 to 23.
    static func hourHistogram(days: [String: DayStat]) -> [Int] {
        var out = [Int](repeating: 0, count: 24)
        for day in days.values {
            for (hour, words) in day.hours {
                if let index = Int(hour), index >= 0, index < 24 {
                    out[index] += words
                }
            }
        }
        return out
    }

    /// Speaking pace per day for the last `lastN` days, newest last.
    /// Days with too little speaking time return nil so the chart can draw a
    /// gap: rendering them as zero would claim the user slowed to a halt.
    static func wpmSeries(
        days: [String: DayStat], lastN: Int = 30, today: Date = Date()
    ) -> [(day: String, wpm: Double?)] {
        let calendar = Calendar.current
        return (0..<lastN).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let key = dayKey(date)
            guard let day = days[key] else { return (key, nil) }
            let pace = wpm(words: day.words, seconds: day.seconds)
            return (key, pace > 0 ? pace : nil)
        }
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
        Store.save(data, to: file, label: "stats")
    }
}
