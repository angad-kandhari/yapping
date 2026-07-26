import AppKit

// Refuse to double-run: two instances would both grab the fn key and mic
// (e.g. launchd starting the agent while a manually launched copy runs)
let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.angad.dictate")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    NSLog("another dictate instance is already running, exiting")
    exit(0)
}

// Menu-bar-only app: no Dock icon, no main window
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
