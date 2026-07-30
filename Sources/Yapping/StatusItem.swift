import AppKit

/// Menu bar indicator built around the dictate logo (five rounded bars).
///
/// The bars are drawn programmatically so the logo itself can animate:
/// - idle: the logo at its natural rest heights
/// - recording: bar heights driven by live mic levels, eased between frames
/// - processing: the logo dimmed while transcription finishes
final class StatusItem {
    enum State {
        case idle, recording, processing
    }

    // Logo geometry from icon-pack/menubar/yapping-menubar.svg (24-grid:
    // six bars at x 3.5/7/10.5/14/17.5/21, heights 4/9/15/7/11/3, stroke 2,
    // round caps), scaled 0.75x into an 18 pt menu bar canvas.
    private static let canvas: CGFloat = 18
    private static let barWidth: CGFloat = 1.5
    private static let barCenters: [CGFloat] = [2.625, 5.25, 7.875, 10.5, 13.125, 15.75]
    private static let restHeights: [CGFloat] = [3, 6.75, 11.25, 5.25, 8.25, 2.25]
    private static let minHeight: CGFloat = 2.25
    private static let maxHeight: CGFloat = 16
    /// RMS to height scaling: normal speech RMS is roughly 0.01-0.1.
    private static let gain: Float = 80

    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "Hold \u{1F310} (fn) to talk", action: nil, keyEquivalent: "")
    private var state: State = .idle
    private var levels: [Float] = Array(repeating: 0, count: 6)
    private var displayed: [CGFloat] = StatusItem.restHeights
    private var settled = false
    private var timer: Timer?

    private var listenItem: NSMenuItem?
    private var updatesItem: NSMenuItem?
    private var updateAvailable = false
    private var dropHandler: (([URL]) -> Void)?

    // Brand.accent (#FF5A1F) as NSColor, for the menu item dot
    private static let accent = NSColor(red: 1.0, green: 0.353, blue: 0.122, alpha: 1)

    init(
        onSettings: @escaping () -> Void,
        onHistory: @escaping () -> Void,
        onTranscribeFile: @escaping () -> Void,
        onListen: @escaping () -> Void,
        onSetup: @escaping () -> Void,
        onUpdates: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let target = MenuTarget(
            onSettings: onSettings, onHistory: onHistory,
            onTranscribeFile: onTranscribeFile, onListen: onListen,
            onSetup: onSetup, onUpdates: onUpdates, onQuit: onQuit)
        objc_setAssociatedObject(menu, "target", target, .OBJC_ASSOCIATION_RETAIN)

        func add(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = target
            menu.addItem(entry)
            return entry
        }
        _ = add("History", #selector(MenuTarget.history), "h")
        _ = add("Settings", #selector(MenuTarget.settings), ",")
        menu.addItem(.separator())
        _ = add("Transcribe File", #selector(MenuTarget.transcribeFile))
        listenItem = add("Listen to System Audio", #selector(MenuTarget.listen), "l")
        menu.addItem(.separator())
        _ = add("Setup Assistant", #selector(MenuTarget.setup))
        updatesItem = add("Check for Updates", #selector(MenuTarget.updates))
        menu.addItem(.separator())
        _ = add("Quit Yapping", #selector(MenuTarget.quit), "q")
        item.menu = menu

        redraw()
        // 20 fps while animating; skips work once the logo settles at rest
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Badge the icon and the Check for Updates item while a newer release
    /// exists; cleared once the user opens the Updates window.
    func setUpdateAvailable(_ available: Bool) {
        DispatchQueue.main.async {
            guard self.updateAvailable != available else { return }
            self.updateAvailable = available
            if let item = self.updatesItem {
                if available {
                    let title = NSMutableAttributedString(
                        string: "\u{25CF} ",
                        attributes: [.foregroundColor: Self.accent,
                                     .font: NSFont.menuFont(ofSize: 0)])
                    title.append(NSAttributedString(
                        string: "Check for Updates",
                        attributes: [.foregroundColor: NSColor.labelColor,
                                     .font: NSFont.menuFont(ofSize: 0)]))
                    item.attributedTitle = title
                } else {
                    item.attributedTitle = nil
                }
            }
            self.redraw()
        }
    }

    /// Reflect Listen mode in the menu.
    func setListening(_ listening: Bool) {
        DispatchQueue.main.async {
            self.listenItem?.title = listening
                ? "\u{25CF} Stop Listening"
                : "Listen to System Audio"
        }
    }

    /// Files dropped on the menu bar icon become transcription jobs.
    func acceptDrops(_ handler: @escaping ([URL]) -> Void) {
        dropHandler = handler
        guard let button = item.button else { return }
        let drop = DropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onFiles = { [weak self] urls in self?.dropHandler?(urls) }
        button.addSubview(drop)
    }

    /// Thread-safe: called from the audio tap thread. Newest level enters on
    /// the right and scrolls left through the logo's bars.
    func pushLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.levels.removeFirst()
            self.levels.append(level)
        }
    }

    func setState(_ state: State, detail: String? = nil) {
        DispatchQueue.main.async {
            self.state = state
            self.settled = false
            switch state {
            case .idle:
                self.statusLine.title = "Hold \u{1F310} (fn) to talk"
            case .recording:
                self.levels = Array(repeating: 0, count: 6)
                self.statusLine.title = detail.map { "Listening (\($0))..." } ?? "Listening..."
            case .processing:
                self.statusLine.title = detail.map { "\($0)..." } ?? "Transcribing..."
            }
        }
    }

    private func tick() {
        if state != .recording && settled { return }

        let targets: [CGFloat]
        if state == .recording {
            targets = levels.map { level in
                let t = CGFloat(min(1, level * Self.gain))
                return Self.minHeight + (Self.maxHeight - Self.minHeight) * t
            }
        } else {
            targets = Self.restHeights
        }

        // Ease toward targets: fast enough to feel live, slow enough to flow
        var maxDelta: CGFloat = 0
        for i in 0..<displayed.count {
            let delta = targets[i] - displayed[i]
            displayed[i] += delta * 0.45
            maxDelta = max(maxDelta, abs(delta))
        }
        if state != .recording && maxDelta < 0.05 {
            displayed = targets
            settled = true
        }
        redraw()
    }

    private func redraw() {
        let heights = displayed
        let update = updateAvailable
        let alpha: CGFloat = state == .processing ? 0.4 : 1.0
        let size = NSSize(width: Self.canvas, height: Self.canvas)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.withAlphaComponent(alpha).setFill()
            for (i, cx) in Self.barCenters.enumerated() {
                let h = heights[i]
                let rect = NSRect(
                    x: cx - Self.barWidth / 2,
                    y: (Self.canvas - h) / 2,
                    width: Self.barWidth,
                    height: h
                )
                NSBezierPath(roundedRect: rect, xRadius: Self.barWidth / 2,
                             yRadius: Self.barWidth / 2).fill()
            }
            return true
        }
        // Template rendering: macOS tints it for light/dark menu bars
        image.isTemplate = true
        item.button?.image = image
        // Update available: a green up arrow beside the logo. It rides as
        // the button title because template images cannot carry color.
        if update {
            item.button?.attributedTitle = Self.updateArrow
            item.button?.imagePosition = .imageLeft
        } else {
            item.button?.title = ""
            item.button?.imagePosition = .imageOnly
        }
    }

    private static let updateArrow = NSAttributedString(
        string: "\u{2191}",
        attributes: [
            .foregroundColor: NSColor.systemGreen,
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
        ])
}

private final class MenuTarget: NSObject {
    private let onSettings: () -> Void
    private let onHistory: () -> Void
    private let onTranscribeFile: () -> Void
    private let onListen: () -> Void
    private let onSetup: () -> Void
    private let onUpdates: () -> Void
    private let onQuit: () -> Void

    init(
        onSettings: @escaping () -> Void,
        onHistory: @escaping () -> Void,
        onTranscribeFile: @escaping () -> Void,
        onListen: @escaping () -> Void,
        onSetup: @escaping () -> Void,
        onUpdates: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onSettings = onSettings
        self.onHistory = onHistory
        self.onTranscribeFile = onTranscribeFile
        self.onListen = onListen
        self.onSetup = onSetup
        self.onUpdates = onUpdates
        self.onQuit = onQuit
    }

    @objc func settings() { onSettings() }
    @objc func history() { onHistory() }
    @objc func transcribeFile() { onTranscribeFile() }
    @objc func listen() { onListen() }
    @objc func setup() { onSetup() }
    @objc func updates() { onUpdates() }
    @objc func quit() { onQuit() }
}

/// Transparent drag target layered over the status item button.
private final class DropView: NSView {
    var onFiles: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    // Clicks forward to the status button so the menu still opens
    override func mouseDown(with event: NSEvent) {
        (superview as? NSStatusBarButton)?.performClick(nil)
    }
}
