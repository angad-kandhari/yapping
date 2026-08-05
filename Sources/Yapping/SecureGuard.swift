import Foundation

/// Decides whether a dictation should be refused because the cursor is in a
/// password field. Pure, so the truth table is tested rather than trusted.
///
/// Read the honesty note in AXContext.focusSecurity before changing this:
/// `unknown` deliberately allows. We can act on a positive signal; we cannot
/// manufacture a negative one, and a guard that fired on silence would break
/// dictation in every Electron app.
enum SecureGuard {
    static func shouldBlock(_ check: AXContext.SecureCheck, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch check {
        case .secure: return true
        case .notSecure, .unknown: return false
        }
    }

    static let blockedNotice = "That looks like a password field, so the mic did not start. Turn this off in Settings, Behavior."
}
