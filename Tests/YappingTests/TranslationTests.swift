import XCTest
@testable import yapping

final class TranslationTests: XCTestCase {

    // MARK: - Which language wins

    func testStyleOverridesTheGlobalDefault() {
        let style = Style(name: "Formal", appPatterns: [], prompt: "", targetLanguage: "de")
        XCTAssertEqual(Translation.resolve(style: style, fallback: "es"), "de")
    }

    func testEmptyStyleValueInheritsTheDefault() {
        let style = Style(name: "Casual", appPatterns: [], prompt: "")
        XCTAssertEqual(Translation.resolve(style: style, fallback: "es"), "es")
    }

    func testNoStyleAndNoDefaultMeansNoTranslation() {
        XCTAssertNil(Translation.resolve(style: nil, fallback: ""))
        let style = Style(name: "Casual", appPatterns: [], prompt: "")
        XCTAssertNil(Translation.resolve(style: style, fallback: ""))
    }

    // MARK: - Plausibility, which must be far looser than cleanup's

    func testContractingScriptsAreAccepted() {
        // English into Japanese roughly a third of the characters
        let english = String(repeating: "a", count: 300)
        let japanese = String(repeating: "あ", count: 100)
        XCTAssertTrue(Translation.looksSane(source: english, output: japanese),
                      "cleanup's 0.3x floor would wrongly reject a correct translation")
    }

    func testExpandingScriptsAreAccepted() {
        let english = String(repeating: "a", count: 100)
        let german = String(repeating: "b", count: 190)
        XCTAssertTrue(Translation.looksSane(source: english, output: german))
    }

    func testAbsurdOutputsAreRejected() {
        let source = String(repeating: "a", count: 200)
        XCTAssertFalse(Translation.looksSane(source: source, output: ""))
        XCTAssertFalse(Translation.looksSane(source: source,
                                             output: String(repeating: "b", count: 20)))
        XCTAssertFalse(Translation.looksSane(source: source,
                                             output: String(repeating: "b", count: 900)))
    }

    func testShortPhrasesGetSlack() {
        // "Hi" into a longer greeting must not trip the ceiling
        XCTAssertTrue(Translation.looksSane(source: "Hi", output: "Guten Tag, wie geht es Ihnen"))
    }

    // MARK: - Naming

    func testDisplayNamesAreHumanReadable() {
        XCTAssertEqual(Translation.displayName("es"), "Spanish")
        XCTAssertEqual(Translation.displayName("ja"), "Japanese")
    }

    func testTargetListIsSaneAndDeduplicated() {
        XCTAssertEqual(Set(Translation.targets).count, Translation.targets.count)
        XCTAssertTrue(Translation.targets.contains("zh-Hans"))
    }
}
