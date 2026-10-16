import XCTest
@testable import yapping

final class TextRulesTests: XCTestCase {
    func testReplacementMatchesWholeWordsOnly() {
        let out = TextRules.apply(to: "I said the ai is fine", pairs: [("ai", "A.I.")])
        XCTAssertEqual(out, "I said the A.I. is fine")
    }

    func testReplacementIsCaseInsensitive() {
        XCTAssertEqual(TextRules.apply(to: "Angad and angad", pairs: [("angad", "Angad")]),
                       "Angad and Angad")
    }

    func testMultiWordTriggerAndPunctuationBoundary() {
        XCTAssertEqual(
            TextRules.apply(to: "sign off: my sig.", pairs: [("my sig", "Angad K")]),
            "sign off: Angad K.")
    }

    func testTriggerInsideAWordIsLeftAlone() {
        XCTAssertEqual(TextRules.apply(to: "the periodic table", pairs: [("period", ".")]),
                       "the periodic table")
    }

    func testRegexCharactersInRulesAreLiteral() {
        XCTAssertEqual(TextRules.apply(to: "c++ and c", pairs: [("c++", "C plus plus")]),
                       "C plus plus and c")
        XCTAssertEqual(TextRules.apply(to: "price", pairs: [("price", "$5")]), "$5")
    }

    func testEmptyRulesAreSkipped() {
        XCTAssertEqual(TextRules.apply(to: "unchanged", pairs: [("", "x"), ("  ", "y")]),
                       "unchanged")
    }
}
