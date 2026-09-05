import XCTest
@testable import yapping

final class CleanupTests: XCTestCase {

    // MARK: - Reply detection

    /// The exact failure that shipped: a long dictation that was itself a
    /// request got answered rather than cleaned, and the answer was long
    /// enough to pass the size guard.
    func testAssistantRefusalIsCaught() {
        let raw = "Please use the 3 PDFs attached here and create a bill of materials "
            + "for the retaining wall only. Use the screenshot as reference."
        let cleaned = "I am sorry, but I cannot fulfill your request as it involves "
            + "accessing external files. As an AI model, I do not have the capability to "
            + "open PDF documents. Please provide me with the text content."
        XCTAssertTrue(Cleanup.looksLikeReply(raw: raw, cleaned: cleaned))
    }

    func testPreambleIsCaught() {
        XCTAssertTrue(Cleanup.looksLikeReply(
            raw: "the meeting is moved to thursday",
            cleaned: "Here is the cleaned text: The meeting is moved to Thursday."))
    }

    func testOrdinaryCleanupPasses() {
        XCTAssertFalse(Cleanup.looksLikeReply(
            raw: "hey claude can you um look at this file and tell me what's wrong",
            cleaned: "Hey Claude, can you look at this file and tell me what's wrong?"))
    }

    /// A speaker is allowed to apologise. The phrase only counts against
    /// the model when the speaker never said it.
    func testSpeakersOwnApologyIsNotAReply() {
        let raw = "I'm sorry, but I cannot make the meeting on friday"
        let cleaned = "I'm sorry, but I cannot make the meeting on Friday."
        XCTAssertFalse(Cleanup.looksLikeReply(raw: raw, cleaned: cleaned))
    }

    // MARK: - Marker stripping

    func testMarkersAreStrippedFromTheEdges() {
        XCTAssertEqual(Cleanup.unwrap("<<<\nHello there.\n>>>"), "Hello there.")
        XCTAssertEqual(Cleanup.unwrap("Transcript:\n<<<\nHello there.\n>>>"), "Hello there.")
        XCTAssertEqual(Cleanup.unwrap("Hello there."), "Hello there.")
    }
}
