import XCTest
@testable import yapping

final class ExportTests: XCTestCase {
    private let entries = [
        HistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: 1_780_000_000),
                     appName: "Slack", raw: "um hello there",
                     cleaned: "Hello there.", styleName: "Casual"),
        HistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: 1_780_000_100),
                     appName: "Terminal", raw: "git status", cleaned: "git status"),
    ]

    func testMarkdownIncludesBothTextsWhenTheyDiffer() {
        let out = HistoryExport.markdown(entries)
        XCTAssertTrue(out.contains("Hello there."))
        XCTAssertTrue(out.contains("> raw: um hello there"))
        XCTAssertTrue(out.contains("Slack"))
        XCTAssertTrue(out.contains("_style: Casual_"))
    }

    func testMarkdownSkipsTheRawLineWhenNothingChanged() {
        let out = HistoryExport.markdown([entries[1]])
        XCTAssertTrue(out.contains("git status"))
        XCTAssertFalse(out.contains("> raw:"),
                       "repeating identical text as a quote is noise")
    }

    func testJSONIsStableAndReadable() throws {
        let data = try HistoryExport.json(entries)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"appName\""))
        XCTAssertTrue(text.contains("Hello there."))
        // ISO dates rather than raw doubles, so the file is human readable
        XCTAssertTrue(text.contains("2026-"))
        // Sorted keys keep diffs meaningful across exports
        XCTAssertLessThan(text.range(of: "\"appName\"")!.lowerBound,
                          text.range(of: "\"cleaned\"")!.lowerBound)
    }

    func testEmptyExportsAreValid() throws {
        XCTAssertFalse(HistoryExport.markdown([]).isEmpty)
        XCTAssertEqual(String(decoding: try HistoryExport.json([]), as: UTF8.self), "[\n\n]")
    }
}
