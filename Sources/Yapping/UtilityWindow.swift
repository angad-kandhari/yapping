import AppKit
import SwiftUI

/// Retained window host for SwiftUI content in an accessory (menu bar) app.
/// isReleasedWhenClosed stays false to avoid dealloc-on-close crashes, and
/// activation is forced so the window keys properly without a Dock icon.
final class UtilityWindow<Content: View> {
    private var window: NSWindow?
    private let title: String
    private let makeContent: () -> Content

    init(title: String, content: @escaping () -> Content) {
        self.title = title
        self.makeContent = content
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent())
            let w = NSWindow(contentViewController: hosting)
            w.title = title
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // Brand chrome draws its own header; hide the system titlebar
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // Remember size and position per window across launches
            let autosave = "yapping-window-\(title)"
            if !w.setFrameUsingName(autosave) {
                w.center()
            }
            w.setFrameAutosaveName(autosave)
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
