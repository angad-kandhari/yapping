import CoreGraphics
import Foundation

/// Types text at the cursor with synthetic keyboard events. No clipboard
/// involvement, so live streaming never disturbs what the user has copied.
enum Typist {
    /// CGEvent truncates unicode payloads beyond 20 UTF-16 units.
    private static let chunkLimit = 20

    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + chunkLimit, units.count)
            var chunk = Array(units[index..<end])
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            index = end
        }
    }

    /// Retract characters (volatile refinements, or cancel of a live hold).
    static func backspace(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
