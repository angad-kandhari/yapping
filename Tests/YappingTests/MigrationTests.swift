import XCTest
@testable import yapping

/// Every fixture here is JSON as an older build would have written it.
/// If any of these fail, upgrading destroys user data.
final class MigrationTests: XCTestCase {
    private let decoder = JSONDecoder()

    // MARK: - Styles (the worst case: hand-written prompts)

    func testStyleFromBeforeVoiceCommandsAndTranslation() throws {
        let legacy = """
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Formal",
          "appPatterns":["com.apple.mail"],"prompt":"Professional email prose.",
          "verbatim":false}]
        """
        let styles = try decoder.decode([Style].self, from: Data(legacy.utf8))
        XCTAssertEqual(styles.count, 1)
        XCTAssertEqual(styles[0].name, "Formal")
        XCTAssertEqual(styles[0].prompt, "Professional email prose.")
        // New fields take their defaults instead of throwing
        XCTAssertTrue(styles[0].voiceCommands)
        XCTAssertEqual(styles[0].targetLanguage, "")
    }

    func testStyleMissingVerbatimStillDecodes() throws {
        let older = """
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Casual",
          "appPatterns":["slack"],"prompt":"Keep it light."}]
        """
        let styles = try decoder.decode([Style].self, from: Data(older.utf8))
        XCTAssertFalse(styles[0].verbatim)
    }

    // MARK: - History

    func testHistoryEntryWithoutStyleName() throws {
        let legacy = """
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","date":774316800,
          "appName":"Slack","raw":"um hello","cleaned":"Hello"}]
        """
        let entries = try decoder.decode([HistoryEntry].self, from: Data(legacy.utf8))
        XCTAssertEqual(entries[0].appName, "Slack")
        XCTAssertEqual(entries[0].cleaned, "Hello")
        XCTAssertNil(entries[0].styleName)
    }

    func testHistoryRoundTrip() throws {
        let entry = HistoryEntry(id: UUID(), date: Date(), appName: "Mail",
                                 raw: "raw", cleaned: "clean", styleName: "Formal")
        let data = try JSONEncoder().encode([entry])
        let back = try decoder.decode([HistoryEntry].self, from: data)
        XCTAssertEqual(back[0].styleName, "Formal")
        XCTAssertEqual(back[0].raw, "raw")
    }

    // MARK: - Transcripts

    func testTranscriptEntryDecodesWithMissingOptionalFields() throws {
        let legacy = """
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","date":774316800,
          "kind":"listen","title":"Standup","seconds":120,"words":300,
          "text":"hello there","summary":""}]
        """
        let entries = try decoder.decode([TranscriptEntry].self, from: Data(legacy.utf8))
        XCTAssertEqual(entries[0].kind, .listen)
        XCTAssertEqual(entries[0].words, 300)
    }

    // MARK: - Stats v1 to v2

    func testStatsV1DecodesAndKeepsEveryCount() throws {
        let v1 = """
        {"totalWords":12437,"totalSessions":214,"totalSeconds":5240.5,
         "days":{"2026-07-01":{"words":420,"sessions":7,"seconds":180.0}},
         "apps":{"Slack":{"words":900,"sessions":30}},
         "since":774316800,"version":1}
        """
        let data = try decoder.decode(StatsData.self, from: Data(v1.utf8))
        XCTAssertEqual(data.totalWords, 12437)
        XCTAssertEqual(data.totalSessions, 214)
        XCTAssertEqual(data.days["2026-07-01"]?.words, 420)
        XCTAssertEqual(data.apps["Slack"]?.sessions, 30)
        // New buckets exist and are empty rather than absent
        XCTAssertEqual(data.days["2026-07-01"]?.hours, [:])
        XCTAssertEqual(data.styles, [:])

        let (migrated, note) = StatsMigration.migrate(data)
        XCTAssertEqual(migrated.version, StatsData.currentVersion)
        XCTAssertEqual(migrated.totalWords, 12437, "migration must never touch counts")
        XCTAssertNotNil(note)
    }

    func testStatsWithoutSinceIsRepairedFromEarliestDay() throws {
        let noSince = """
        {"totalWords":100,"totalSessions":2,"totalSeconds":60.0,
         "days":{"2026-03-14":{"words":50,"sessions":1,"seconds":30.0},
                 "2026-05-02":{"words":50,"sessions":1,"seconds":30.0}},
         "apps":{},"version":1}
        """
        let data = try decoder.decode(StatsData.self, from: Data(noSince.utf8))
        let (migrated, _) = StatsMigration.migrate(data)
        XCTAssertEqual(StatsStore.dayKey(migrated.since), "2026-03-14",
                       "member-since must come from the earliest recorded day, not today")
    }

    func testMigrationIsIdempotent() throws {
        var data = StatsData()
        data.since = Date(timeIntervalSince1970: 774316800)
        data.version = StatsData.currentVersion
        let (once, note) = StatsMigration.migrate(data)
        XCTAssertNil(note, "an already-current file needs no migration")
        let (twice, secondNote) = StatsMigration.migrate(once)
        XCTAssertNil(secondNote)
        XCTAssertEqual(twice.version, StatsData.currentVersion)
    }

    func testStatsRoundTripPreservesNewBuckets() throws {
        var data = StatsData()
        data.days["2026-08-05"] = DayStat(words: 10, sessions: 1, seconds: 12, hours: ["14": 10])
        data.styles["Formal"] = AppStat(words: 10, sessions: 1)
        let encoded = try JSONEncoder().encode(data)
        let back = try decoder.decode(StatsData.self, from: encoded)
        XCTAssertEqual(back.days["2026-08-05"]?.hours["14"], 10)
        XCTAssertEqual(back.styles["Formal"]?.words, 10)
    }

    // MARK: - Corruption

    func testGarbageAndTruncatedPayloadsThrowRatherThanCrash() {
        let garbage = Data("this is not json".utf8)
        XCTAssertThrowsError(try decoder.decode([HistoryEntry].self, from: garbage))

        let truncated = Data("""
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","date":774316800,"appNa
        """.utf8)
        XCTAssertThrowsError(try decoder.decode([HistoryEntry].self, from: truncated))
        XCTAssertThrowsError(try decoder.decode(StatsData.self, from: garbage))
    }

    func testEntryMissingRequiredIdIsRejected() {
        // id and date are the two fields every build has always written; an
        // entry without them is genuinely unreadable rather than merely old.
        let noID = Data("""
        [{"date":774316800,"appName":"Slack","raw":"a","cleaned":"b"}]
        """.utf8)
        XCTAssertThrowsError(try decoder.decode([HistoryEntry].self, from: noID))
    }

    // MARK: - The rescue path (the whole safety net)

    func testCorruptFileIsRescuedRatherThanSilentlyDropped() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yapping-store-test-\(UUID().uuidString)")
        Store.directoryOverride = temp
        defer {
            Store.directoryOverride = nil
            try? FileManager.default.removeItem(at: temp)
        }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let file = temp.appendingPathComponent("history.json")
        let corrupt = Data(#"[{"id":"broken","date":"#.utf8)
        try corrupt.write(to: file)

        let loaded = Store.load([HistoryEntry].self, from: file, label: "history")
        XCTAssertNil(loaded, "unreadable data must not be returned")

        let rescued = try FileManager.default.contentsOfDirectory(
            at: temp.appendingPathComponent("rescued"), includingPropertiesForKeys: nil)
        XCTAssertEqual(rescued.count, 1, "the bytes must be kept, not dropped")
        XCTAssertEqual(try Data(contentsOf: rescued[0]), corrupt,
                       "the rescue copy must be byte-identical to what we could not read")
    }

    func testMissingFileIsNotTreatedAsCorruption() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yapping-store-test-\(UUID().uuidString)")
        Store.directoryOverride = temp
        defer { Store.directoryOverride = nil }

        let loaded = Store.load([HistoryEntry].self,
                                from: temp.appendingPathComponent("nope.json"),
                                label: "history")
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temp.appendingPathComponent("rescued").path),
            "a fresh install must not create rescue files")
    }

    func testSaveIsAtomicAndOwnerOnly() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yapping-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let file = temp.appendingPathComponent("stats.json")
        Store.save(StatsData(), to: file, label: "stats")

        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "stores hold private text and must stay owner-only")
    }
}
