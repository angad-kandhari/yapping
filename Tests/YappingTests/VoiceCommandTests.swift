import XCTest
@testable import yapping

final class VoiceCommandTests: XCTestCase {

    /// prepare then rejoin with no model in between: the identity path.
    private func roundTrip(_ spoken: String) -> String {
        let prepared = VoiceCommands.prepare(spoken)
        return VoiceCommands.rejoin(prepared.segments, prepared)
    }

    // MARK: - Punctuation, inserted before cleanup as real characters

    func testPunctuationCommands() {
        XCTAssertEqual(roundTrip("hello comma world"), "hello, world")
        XCTAssertEqual(roundTrip("are you sure question mark"), "are you sure?")
        XCTAssertEqual(roundTrip("stop exclamation mark"), "stop!")
        XCTAssertEqual(roundTrip("done period"), "done.")
        XCTAssertEqual(roundTrip("done full stop"), "done.")
    }

    func testLongerPhraseWinsOverShorter() {
        XCTAssertEqual(roundTrip("wow exclamation point"), "wow!")
    }

    func testCommandWordsInsideOtherWordsAreLeftAlone() {
        XCTAssertEqual(roundTrip("periodic table"), "periodic table")
        XCTAssertEqual(roundTrip("commander in chief"), "commander in chief")
    }

    func testPlainTextIsUntouched() {
        XCTAssertEqual(roundTrip("just a normal sentence"), "just a normal sentence")
    }

    // MARK: - Line breaks, held outside the model entirely

    func testNewlineSplitsIntoSegments() {
        let prepared = VoiceCommands.prepare("first new line second")
        XCTAssertEqual(prepared.segments, ["first", "second"])
        XCTAssertEqual(prepared.separators, ["\n"])
        XCTAssertEqual(VoiceCommands.rejoin(prepared.segments, prepared), "first\nsecond")
    }

    func testNewParagraphUsesABlankLine() {
        let prepared = VoiceCommands.prepare("intro new paragraph body")
        XCTAssertEqual(prepared.separators, ["\n\n"])
        XCTAssertEqual(VoiceCommands.rejoin(prepared.segments, prepared), "intro\n\nbody")
    }

    func testMultipleBreaks() {
        let prepared = VoiceCommands.prepare("one new line two new paragraph three")
        XCTAssertEqual(prepared.segments, ["one", "two", "three"])
        XCTAssertEqual(prepared.separators, ["\n", "\n\n"])
    }

    /// The point of the redesign: whatever cleanup does to a segment, the
    /// break between segments cannot be destroyed.
    func testBreaksSurviveEvenIfCleanupRewritesEverySegment() {
        let prepared = VoiceCommands.prepare("um first thing new paragraph and second")
        let asIfCleaned = ["First thing.", "And second."]
        XCTAssertEqual(VoiceCommands.rejoin(asIfCleaned, prepared),
                       "First thing.\n\nAnd second.")
    }

    func testMismatchedSegmentCountFallsBackToPreparedText() {
        let prepared = VoiceCommands.prepare("a new line b")
        // A model that returned the wrong number of pieces must not lose words
        let out = VoiceCommands.rejoin(["only one piece"], prepared)
        XCTAssertEqual(out, "a\nb")
    }

    func testPlainTextIsASingleSegment() {
        let prepared = VoiceCommands.prepare("nothing special here")
        XCTAssertTrue(prepared.isPlain)
        XCTAssertEqual(prepared.segments.count, 1)
    }

    // MARK: - Transforms

    func testScratchThatDropsThePrecedingClause() {
        XCTAssertEqual(VoiceCommands.scratch("ship it friday. no scratch that"),
                       "ship it friday.")
        XCTAssertEqual(VoiceCommands.scratch("meet at noon delete that"), "")
    }

    func testScratchAtTheStartClearsOnlyItself() {
        XCTAssertEqual(VoiceCommands.scratch("scratch that hello"), "hello")
    }

    func testCapsOnOff() {
        XCTAssertEqual(VoiceCommands.applyCaps("caps on hello world caps off done"),
                       "Hello World done")
    }

    func testUnterminatedCapsRunsToTheEnd() {
        XCTAssertEqual(VoiceCommands.applyCaps("caps on hello world"), "Hello World")
    }

    // MARK: - Disabled

    func testDisabledLeavesTextExactlyAsSpoken() {
        let prepared = VoiceCommands.prepare("hello comma world new line more", enabled: false)
        XCTAssertEqual(prepared.segments, ["hello comma world new line more"])
        XCTAssertTrue(prepared.isPlain)
    }

    // MARK: - Spacing

    func testSpacingAroundInsertedPunctuation() {
        XCTAssertEqual(roundTrip("wait comma what question mark"), "wait, what?")
    }

    // MARK: - Composition with "send it"

    func testSendItStillStripsAfterATrailingPeriod() {
        let text = roundTrip("ship the build send it period")
        XCTAssertEqual(text, "ship the build send it.")
        XCTAssertEqual(AppDelegate.stripSendCommand(from: text), "ship the build")
    }
}

// MARK: - Spoken punctuation must not touch the speaker's own punctuation

final class TidyTests: XCTestCase {
    private func roundTrip(_ spoken: String) -> String {
        let prepared = VoiceCommands.prepare(spoken)
        return VoiceCommands.rejoin(prepared.segments, prepared)
    }

    /// The bug: every period not followed by a digit got a space after it,
    /// so "example.com" was pasted as "example. com" into a terminal.
    func testDottedTokensSurvive() {
        XCTAssertEqual(roundTrip("go to example.com now"), "go to example.com now")
        XCTAssertEqual(roundTrip("e.g. the U.S. team"), "e.g. the U.S. team")
        XCTAssertEqual(roundTrip("run ls -la ./src"), "run ls -la ./src")
        XCTAssertEqual(roundTrip("email a@b.co"), "email a@b.co")
        XCTAssertEqual(roundTrip("wait... what"), "wait... what")
        XCTAssertEqual(roundTrip("version 3.5 costs $1,000"), "version 3.5 costs $1,000")
    }

    func testSpokenPunctuationIsStillSpaced() {
        XCTAssertEqual(roundTrip("hello comma world"), "hello, world")
        XCTAssertEqual(roundTrip("one period two"), "one. two")
        XCTAssertEqual(roundTrip("really question mark yes"), "really? yes")
    }

    func testMixedSpokenAndWrittenPunctuation() {
        XCTAssertEqual(roundTrip("open example.com comma then ./run period done"),
                       "open example.com, then ./run. done")
    }

    func testNoMarkerLeaksIntoOutput() {
        let out = roundTrip("a comma b new line c period")
        XCTAssertFalse(out.contains("\u{0002}"))
        XCTAssertFalse(out.contains("\u{0001}"))
        XCTAssertEqual(out, "a, b\nc.")
    }
}
