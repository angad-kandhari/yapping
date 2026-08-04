import AppKit

/// If the app is launched from a DMG, Downloads, or a translocated path,
/// offer to move it to /Applications. Running outside /Applications breaks
/// launch-at-login and makes permission grants flaky, so this catches the
/// classic double-clicked-it-inside-the-DMG install.
enum MoveToApplications {
    private static let destination = URL(fileURLWithPath: "/Applications/Yapping.app")

    static func offerIfNeeded() {
        let current = Bundle.main.bundleURL
        let path = current.path
        // Already home, or a development build: nothing to do
        guard !path.hasPrefix("/Applications/"),
              !path.contains("/.build/") else { return }

        // Respect a "stop asking": declining forever should be one click
        let suppressKey = "moveToApplicationsSuppressed"
        guard !UserDefaults.standard.bool(forKey: suppressKey) else { return }

        let alert = NSAlert()
        alert.messageText = "Move yapping to Applications?"
        alert.informativeText = "Yapping works best from the Applications folder: launch at login and permissions depend on a stable home. This copies the app there and relaunches it."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: current, to: destination)
            // Relaunch the installed copy; leave the original (a DMG volume
            // is read-only anyway, and Downloads copies are harmless)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: destination, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            let fail = NSAlert()
            fail.messageText = "Could not move the app"
            fail.informativeText = "Drag Yapping.app to the Applications folder in Finder instead. (\(error.localizedDescription))"
            fail.runModal()
        }
    }
}
