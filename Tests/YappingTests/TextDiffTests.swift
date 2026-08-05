import XCTest
@testable import yapping

final class TextDiffTests: XCTestCase {

    private func spans(_ before: String, _ after: String) -> [TextDiff.Span] {
        guard let spans = TextDiff.words(from: before, to: after) else {
            XCTFail("expected a diff, got nil")
            return []
        }
        return spans
    }

    func testIdenticalTextHasNoCorrections() {
        let result = spans("the meeting is on friday", "the meeting is on friday")
        XCTAssertEqual(result.map(\.kind), [.same])
        XCTAssertEqual(TextDiff.corrections(result), 0)
    }

    /// A substitution reads as one correction, not as a deletion plus an
    /// insertion, because that is how a person counts it.
    func testSubstitutionCountsOnce() {
        let result = spans("me and him was going", "He and I were going")
        XCTAssertEqual(TextDiff.corrections(result), 2)
    }

    func testAddedWordsAreMarkedAdded() {
        let result = spans("going to store", "going to the store")
        XCTAssertEqual(result, [
            TextDiff.Span(kind: .same, text: "going to"),
            TextDiff.Span(kind: .added, text: "the"),
            TextDiff.Span(kind: .same, text: "store"),
        ])
        XCTAssertEqual(TextDiff.corrections(result), 1)
    }

    func testRemovedFillerIsMarkedRemoved() {
        let result = spans("um so we should ship it", "so we should ship it")
        XCTAssertEqual(result.first, TextDiff.Span(kind: .removed, text: "um"))
        XCTAssertEqual(TextDiff.corrections(result), 1)
    }

    /// Punctuation stays attached to its word, so gaining a period is a
    /// visible change rather than a silent one.
    func testPunctuationCountsAsAChange() {
        let result = spans("we ship friday", "we ship friday.")
        XCTAssertEqual(TextDiff.corrections(result), 1)
    }

    func testEmptySidesDoNotCrash() {
        XCTAssertEqual(TextDiff.words(from: "", to: ""), [])
        XCTAssertEqual(spans("", "hello").map(\.kind), [.added])
        XCTAssertEqual(spans("hello", "").map(\.kind), [.removed])
    }

    /// Long transcripts report "no diff available" rather than spending the
    /// time on a table nobody asked for.
    func testVeryLongTextIsSkipped() {
        let long = String(repeating: "word ", count: TextDiff.limit + 1)
        XCTAssertNil(TextDiff.words(from: long, to: long))
    }

    func testWordsAreNeverLostFromEitherSide() {
        let before = "i was thinking we could maybe ship the thing on friday"
        let after = "I was thinking we could ship it on Friday."
        let result = spans(before, after)
        let kept = result.filter { $0.kind != .added }.map(\.text).joined(separator: " ")
        let pasted = result.filter { $0.kind != .removed }.map(\.text).joined(separator: " ")
        XCTAssertEqual(kept, before)
        XCTAssertEqual(pasted, after)
    }
}
