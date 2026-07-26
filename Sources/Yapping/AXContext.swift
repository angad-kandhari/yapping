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

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
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
