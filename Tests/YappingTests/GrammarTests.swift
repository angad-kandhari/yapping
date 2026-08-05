import XCTest
@testable import yapping

final class GrammarTests: XCTestCase {

    // MARK: - Resolution

    func testStyleOverridesTheGlobalSetting() {
        let style = Style(name: "Formal", appPatterns: [], prompt: "", grammar: "strict")
        XCTAssertEqual(Grammar.resolve(style: style, fallback: "light"), .strict)
    }

    func testEmptyStyleValueInheritsTheGlobalSetting() {
        let style = Style(name: "Casual", appPatterns: [], prompt: "")
        XCTAssertEqual(Grammar.resolve(style: style, fallback: "strict"), .strict)
        XCTAssertEqual(Grammar.resolve(style: nil, fallback: "strict"), .strict)
    }

    /// A value written by a future build, or a corrupted default, must not
    /// silently turn into the more aggressive setting.
    func testUnknownValuesFallBackToLight() {
        XCTAssertEqual(Grammar.resolve(style: nil, fallback: ""), .light)
        XCTAssertEqual(Grammar.resolve(style: nil, fallback: "aggressive"), .light)
    }

    // MARK: - Prompt rules

    func testLightForbidsRestructuringAndStrictAllowsIt() {
        XCTAssertTrue(Grammar.light.rules.contains("Do NOT summarize, restructure"))
        XCTAssertFalse(Grammar.strict.rules.contains("restructure"))
        XCTAssertTrue(Grammar.strict.rules.contains("word order"))
    }

    /// The whole point of the strict copy: it may move words, it may not
    /// invent content, and it must leave a word it cannot place.
    func testStrictStillProtectsContent() {
        let rules = Grammar.strict.rules
        XCTAssertTrue(rules.contains("never invent a fact"))
        XCTAssertTrue(rules.contains("leave it exactly as it is"))
    }

    func testNoRuleUsesAnEmDash() {
        for level in Grammar.allCases {
            XCTAssertFalse(level.rules.contains("\u{2014}"))
            XCTAssertFalse(level.rules.contains("\u{2013}"))
        }
    }

    // MARK: - Size guard

    func testBothStrengthsRejectSummariesAndRunaways() {
        let original = String(repeating: "word ", count: 20)  // 100 characters
        for level in Grammar.allCases {
            XCTAssertFalse(level.plausible(original: original, cleaned: ""))
            XCTAssertFalse(level.plausible(original: original, cleaned: "too short"))
            XCTAssertFalse(level.plausible(
                original: original, cleaned: String(repeating: "x", count: 400)))
        }
    }

    /// Correcting grammar adds characters: the articles, auxiliaries, and
    /// inflections the speaker dropped are exactly what it puts back. Light
    /// would reject that growth as over-editing.
    func testStrictAcceptsGrowthThatLightRejects() {
        // Light tops out at 1.5x + 40, strict at 1.8x + 60, so 210 characters
        // from 100 sits between the two ceilings.
        let original = String(repeating: "x", count: 100)
        let grown = String(repeating: "y", count: 210)
        XCTAssertFalse(Grammar.light.plausible(original: original, cleaned: grown))
        XCTAssertTrue(Grammar.strict.plausible(original: original, cleaned: grown))
    }

    /// Short dictations need the constant, or a two word phrase gaining a
    /// comma would fail its own guard.
    func testShortTextGetsSlack() {
        XCTAssertTrue(Grammar.light.plausible(original: "hi there", cleaned: "Hi there."))
    }
}
