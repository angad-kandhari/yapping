import ApplicationServices
import Foundation

/// Local-only reads from the focused text field via the Accessibility API.
/// Everything returned here stays on this Mac; it is only ever fed to the
/// local cleanup model. Every call is fallible and returns nil on any error
/// (Electron and web views routinely lie about selections and ranges).
enum AXContext {
    /// Cap context reads; more buys nothing for a cleanup prompt.
    private static let windowRadius = 1000
    private static let maxFieldRead = 50_000

    /// What we could learn about the focused field's secrecy.
    enum SecureCheck {
        case secure      // it says AXSecureTextField; believe it
        case notSecure   // it named a role, and that role is not secure
        case unknown     // no accessibility, or the app told us nothing
    }

    /// Is the focused field a password field?
    ///
    /// This is a mitigation, not a security boundary, and the difference
    /// matters. A positive answer is trustworthy: only an app that explicitly
    /// reports AXSecureTextField produces one. A negative answer is not, and
    /// cannot be: Electron apps, web views, and terminal password prompts
    /// (sudo) report nothing special. Blocking on silence would refuse to
    /// dictate into half the apps people use, so `unknown` means allow.
    static func focusSecurity(timeout: Float = 0.1) -> SecureCheck {
        guard let element = focusedElement(timeout: timeout) else { return .unknown }
        let subrole = string(element, kAXSubroleAttribute)
        let role = string(element, kAXRoleAttribute)
        if isSecure(role: role, subrole: subrole) { return .secure }
        return role == nil && subrole == nil ? .unknown : .notSecure
    }

    /// Pure so the truth table is testable. A few apps report the secure
    /// identity as the role rather than the subrole, so check both.
    static func isSecure(role: String?, subrole: String?) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return subrole == secure || role == secure
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func focusedElement(timeout: Float = 0.3) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// Currently selected text in the frontmost app, if any.
    static func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Text around the caret in the focused field, for cleanup context.
    static func fieldContext() -> String? {
        guard let element = focusedElement() else { return nil }

        // Caret position from the selection range
        var rangeValue: CFTypeRef?
        var caret = 0
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                caret = range.location
            }
        }

        // Prefer a windowed read around the caret
        var window = CFRange(location: max(0, caret - windowRadius),
                             length: windowRadius * 2)
        if let axRange = AXValueCreate(.cfRange, &window) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString,
                axRange, &out) == .success,
               let text = out as? String, !text.isEmpty {
                return text
            }
        }

        // Fallback: whole field value, capped
        var lengthValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &lengthValue) == .success,
           let count = lengthValue as? Int, count > maxFieldRead {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return String(text.suffix(windowRadius * 2))
    }
}
