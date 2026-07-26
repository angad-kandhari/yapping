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

    // Logo geometry from icon-pack/menubar/dictate-menubar.svg (24-grid:
    // bars at x 4/8/12/16/20, heights 4/10/16/10/4, stroke 2, round caps),
    // scaled 0.75x into an 18 pt menu bar canvas.
    private static let canvas: CGFloat = 18
    private static let barWidth: CGFloat = 1.5
    private static let barCenters: [CGFloat] = [3, 6, 9, 12, 15]
    private static let restHeights: [CGFloat] = [3, 7.5, 12, 7.5, 3]
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 16
    /// RMS to height scaling: normal speech RMS is roughly 0.01-0.1.
    private static let gain: Float = 80

    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "Hold \u{1F310} (fn) to talk", action: nil, keyEquivalent: "")
    private var state: State = .idle
    private var levels: [Float] = Array(repeating: 0, count: 5)
    private var displayed: [CGFloat] = StatusItem.restHeights
    private var settled = false
    private var timer: Timer?

    init(onQuit: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Yap", action: #selector(MenuTarget.quit), keyEquivalent: "q")
        let target = MenuTarget(onQuit: onQuit)
        quit.target = target
        objc_setAssociatedObject(menu, "target", target, .OBJC_ASSOCIATION_RETAIN)
        menu.addItem(quit)
        item.menu = menu

        redraw()
        // 20 fps while animating; skips work once the logo settles at rest
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Thread-safe: called from the audio tap thread. Newest level enters on
    /// the right and scrolls left through the logo's bars.
    func pushLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.levels.removeFirst()
            self.levels.append(level)
        }
    }

    func setState(_ state: State) {
        DispatchQueue.main.async {
            self.state = state
            self.settled = false
            switch state {
            case .idle:
                self.statusLine.title = "Hold \u{1F310} (fn) to talk"
            case .recording:
                self.levels = Array(repeating: 0, count: 5)
                self.statusLine.title = "Listening..."
            case .processing:
                self.statusLine.title = "Transcribing..."
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
        item.button?.title = ""
    }
}

private final class MenuTarget: NSObject {
    private let onQuit: () -> Void
    init(onQuit: @escaping () -> Void) { self.onQuit = onQuit }
    @objc func quit() { onQuit() }
}
