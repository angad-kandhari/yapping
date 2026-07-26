import AppKit

// Menu-bar-only app: no Dock icon, no main window
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
