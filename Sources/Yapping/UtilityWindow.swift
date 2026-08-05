import AppKit
import SwiftUI

/// Retained window host for SwiftUI content in an accessory (menu bar) app.
/// isReleasedWhenClosed stays false to avoid dealloc-on-close crashes, and
/// activation is forced so the window keys properly without a Dock icon.
///
/// Closing swaps the SwiftUI tree for an EmptyView so timers, tasks, and
/// network polls inside the content actually stop; reopening rebuilds the
/// content fresh.
final class UtilityWindow<Content: View> {
    private var window: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    private var closeObserver: NSObjectProtocol?
    private var contentCleared = false
    private let title: String
    private let makeContent: () -> Content

    init(title: String, content: @escaping () -> Content) {
        self.title = title
        self.makeContent = content
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AnyView(makeContent()))
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
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { [weak self] _ in
                self?.hosting?.rootView = AnyView(EmptyView())
                self?.contentCleared = true
            }
            self.hosting = hosting
            window = w
        } else if let hosting, contentCleared {
            hosting.rootView = AnyView(makeContent())
            contentCleared = false
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
