import AppKit

// Logging first so everything after -- including a crash -- leaves a trace
Log.start()
Log.installCrashHandler()

// Refuse to double-run: two instances would both grab the fn key and mic
// (e.g. launchd starting the agent while a manually launched copy runs)
let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.angad.dictate")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    Log.info("another yapping instance is already running, exiting")
    exit(0)
}

// Menu-bar-only app: no Dock icon, no main window
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// LSUIElement apps get no main menu for free, which kills cmd-C/V/X/A/Z
// in every text field, cmd-W on windows, and cmd-H while the app is in
// the Dock. Install the minimum.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Hide Yapping",
                action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit Yapping",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All",
                 action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu

let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Close Window",
                   action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowMenu.addItem(withTitle: "Minimize",
                   action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowMenuItem.submenu = windowMenu
app.mainMenu = mainMenu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
