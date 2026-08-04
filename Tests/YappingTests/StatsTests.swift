import XCTest
@testable import yapping

final class StatsTests: XCTestCase {
    private func day(_ key: String) -> Date {
        StatsStore.dayFormatter.date(from: key)!
    }

    func testDayKeyIsStable() {
        XCTAssertEqual(StatsStore.dayKey(day("2026-08-05")), "2026-08-05")
        XCTAssertEqual(StatsStore.dayKey(day("2026-12-31")), "2026-12-31")
    }

    func testWordCount() {
        XCTAssertEqual(StatsStore.wordCount("hold the globe key"), 4)
        XCTAssertEqual(StatsStore.wordCount("  spaced   out\nlines "), 3)
        XCTAssertEqual(StatsStore.wordCount(""), 0)
    }

    func testWPMNeedsRealSpeakingTime() {
        XCTAssertEqual(StatsStore.wpm(words: 100, seconds: 0), 0)
        XCTAssertEqual(StatsStore.wpm(words: 100, seconds: 30), 0)
        XCTAssertEqual(StatsStore.wpm(words: 150, seconds: 60), 150, accuracy: 0.01)
        XCTAssertEqual(StatsStore.wpm(words: 150, seconds: 120), 75, accuracy: 0.01)
    }

    func testMinutesSaved() {
        // 400 words typed at 40wpm = 10 min; spoken in 2 min = 8 saved
        XCTAssertEqual(
            StatsStore.minutesSaved(words: 400, seconds: 120), 8, accuracy: 0.01)
        // Speaking slower than typing never goes negative
        XCTAssertEqual(
            StatsStore.minutesSaved(words: 10, seconds: 600), 0)
    }

    func testStreaksConsecutive() {
        let today = day("2026-08-05")
        let keys: Set<String> = ["2026-08-03", "2026-08-04", "2026-08-05"]
        let result = StatsStore.streaks(dayKeys: keys, today: today)
        XCTAssertEqual(result.current, 3)
        XCTAssertEqual(result.longest, 3)
    }

    func testStreakSurvivesQuietToday() {
        // Nothing dictated yet today: yesterday's run still counts
        let today = day("2026-08-05")
        let keys: Set<String> = ["2026-08-03", "2026-08-04"]
        let result = StatsStore.streaks(dayKeys: keys, today: today)
        XCTAssertEqual(result.current, 2)
    }

    func testStreakBreaksOnMissedDay() {
        let today = day("2026-08-05")
        let keys: Set<String> = ["2026-08-01", "2026-08-02", "2026-08-05"]
        let result = StatsStore.streaks(dayKeys: keys, today: today)
        XCTAssertEqual(result.current, 1)
        XCTAssertEqual(result.longest, 2)
    }

    func testStreakAcrossMonthBoundary() {
        let today = day("2026-08-01")
        let keys: Set<String> = ["2026-07-30", "2026-07-31", "2026-08-01"]
        let result = StatsStore.streaks(dayKeys: keys, today: today)
        XCTAssertEqual(result.current, 3)
        XCTAssertEqual(result.longest, 3)
    }

    func testEmptyStreaks() {
        let result = StatsStore.streaks(dayKeys: [], today: day("2026-08-05"))
        XCTAssertEqual(result.current, 0)
        XCTAssertEqual(result.longest, 0)
    }

    func testStripSendCommand() {
        XCTAssertEqual(AppDelegate.stripSendCommand(from: "hello there, send it"), "hello there")
        XCTAssertEqual(AppDelegate.stripSendCommand(from: "Send it!"), nil)  // nothing left
        XCTAssertNil(AppDelegate.stripSendCommand(from: "send it to the printer"))
    }
}
