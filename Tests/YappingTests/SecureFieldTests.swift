import XCTest
@testable import yapping

/// The guard's whole job is to be right about a positive signal and humble
/// about everything else. These lock that behaviour down.
final class SecureFieldTests: XCTestCase {
    private let secure = kAXSecureTextFieldSubrole as String

    func testSubroleIdentifiesASecureField() {
        XCTAssertTrue(AXContext.isSecure(role: "AXTextField", subrole: secure))
    }

    func testRoleAloneAlsoCounts() {
        // A few apps report the secure identity as the role, not the subrole
        XCTAssertTrue(AXContext.isSecure(role: secure, subrole: nil))
    }

    func testOrdinaryFieldsAreNotSecure() {
        XCTAssertFalse(AXContext.isSecure(role: "AXTextField", subrole: nil))
        XCTAssertFalse(AXContext.isSecure(role: "AXTextArea", subrole: "AXSearchField"))
        XCTAssertFalse(AXContext.isSecure(role: nil, subrole: nil))
        XCTAssertFalse(AXContext.isSecure(role: "AXWebArea", subrole: nil))
    }

    func testBlocksOnlyOnAPositiveSignal() {
        XCTAssertTrue(SecureGuard.shouldBlock(.secure, enabled: true))
        XCTAssertFalse(SecureGuard.shouldBlock(.notSecure, enabled: true))
    }

    func testUnknownAllowsDictation() {
        // The load-bearing decision: Electron apps, web views, and sudo
        // prompts tell us nothing. Blocking on silence would make yapping
        // useless in half the apps people dictate into.
        XCTAssertFalse(SecureGuard.shouldBlock(.unknown, enabled: true),
                       "unknown must allow; we cannot manufacture a negative signal")
    }

    func testDisabledNeverBlocks() {
        XCTAssertFalse(SecureGuard.shouldBlock(.secure, enabled: false))
        XCTAssertFalse(SecureGuard.shouldBlock(.unknown, enabled: false))
    }
}
