import AppKit
import Carbon.HIToolbox

/// Inserts text into the frontmost app via clipboard + synthetic cmd-V,
/// then restores the previous plain-text clipboard contents.
enum Paster {
    /// Asks clipboard managers not to store the dictated text.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("1", forType: concealedType)

        // Let the pasteboard settle before the synthetic paste
        usleep(50_000)
        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        if let previous {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
    }
}
