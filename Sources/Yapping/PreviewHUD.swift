import AppKit

/// The Dock companion. Two states:
/// - idle: a tiny dim capsule sitting just above the Dock, barely there
/// - listening: on fn-hold it blooms into a wide, short pill where the
///   yapping bars dance with your voice; shrinks back on release
final class WaveformHUD {
    // Panel is always active-size; the pill animates inside it
    private static let panelSize = NSSize(width: 220, height: 48)
    private static let idleFrame = NSRect(x: (220 - 64) / 2, y: 0, width: 64, height: 9)
    private static let activeFrame = NSRect(x: 10, y: 0, width: 200, height: 42)

    private var panel: NSPanel?
    private var pill: NSVisualEffectView?
    private var idleBar: NSView?
    private var waveView: WaveformView?
    private var visible = false

    /// Show the idle sliver (call at launch and on release).
    func showIdle() {
        DispatchQueue.main.async {
            if self.panel == nil { self.makePanel() }
            if !self.visible {
                self.position()
                self.panel?.alphaValue = 1
                self.panel?.orderFrontRegardless()
                self.visible = true
            }
            self.waveView?.stop()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.pill?.animator().frame = Self.idleFrame
                self.pill?.layer?.cornerRadius = Self.idleFrame.height / 2
                self.waveView?.animator().alphaValue = 0
                self.idleBar?.animator().alphaValue = 1
            }
        }
    }

    /// Bloom into the listening pill (call on fn-press).
    func showActive() {
        DispatchQueue.main.async {
            if self.panel == nil { self.makePanel() }
            if !self.visible {
                self.position()
                self.panel?.alphaValue = 1
                self.panel?.orderFrontRegardless()
                self.visible = true
            }
            self.waveView?.reset()
            self.waveView?.start()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.pill?.animator().frame = Self.activeFrame
                self.pill?.layer?.cornerRadius = Self.activeFrame.height / 2
                self.waveView?.animator().alphaValue = 1
                self.idleBar?.animator().alphaValue = 0
            }
        }
    }

    /// Remove entirely (setting turned off).
    func remove() {
        DispatchQueue.main.async {
            self.waveView?.stop()
            self.panel?.orderOut(nil)
            self.visible = false
        }
    }

    /// Thread-safe: called from the audio tap thread.
    func pushLevel(_ level: Float) {
        DispatchQueue.main.async { self.waveView?.push(level) }
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let pill = NSVisualEffectView(frame: Self.idleFrame)
        pill.material = .hudWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Self.idleFrame.height / 2
        pill.layer?.masksToBounds = true

        // Faint capsule so the idle sliver reads against any wallpaper
        let idleBar = NSView(frame: pill.bounds)
        idleBar.autoresizingMask = [.width, .height]
        idleBar.wantsLayer = true
        idleBar.layer?.backgroundColor =
            NSColor.white.withAlphaComponent(0.22).cgColor
        pill.addSubview(idleBar)

        let wave = WaveformView(frame: NSRect(origin: .zero, size: Self.activeFrame.size))
        wave.autoresizingMask = [.width, .height]
        wave.alphaValue = 0
        pill.addSubview(wave)

        panel.contentView?.addSubview(pill)
        self.pill = pill
        self.idleBar = idleBar
        self.waveView = wave
        self.panel = panel
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame  // excludes the Dock
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 10))
    }
}

/// The six logo bars, stretched wide and kept short, eased at 30 fps.
private final class WaveformView: NSView {
    // Logo geometry (24-grid): wide horizontal spread, compact height
    private static let scaleX: CGFloat = 7
    private static let scaleY: CGFloat = 1.5
    private static let barCenters: [CGFloat] = [3.5, 7, 10.5, 14, 17.5, 21].map { $0 * scaleX }
    private static let restHeights: [CGFloat] = [4, 9, 15, 7, 11, 3].map { $0 * scaleY }
    private static let barWidth: CGFloat = 5
    private static let maxHeight: CGFloat = 32
    private static let gain: Float = 80
    private static let contentWidth: CGFloat = 24.5 * scaleX

    private var levels: [Float] = Array(repeating: 0, count: 6)
    private var displayed: [CGFloat] = WaveformView.restHeights
    private var timer: Timer?

    func reset() {
        levels = Array(repeating: 0, count: 6)
        displayed = Self.restHeights
        needsDisplay = true
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    private func tick() {
        for i in 0..<displayed.count {
            let t = CGFloat(min(1, levels[i] * Self.gain))
            // Silence rests at the logo pose; speech pushes bars toward full
            let target = Self.restHeights[i] + (Self.maxHeight - Self.restHeights[i]) * t
            displayed[i] += (target - displayed[i]) * 0.5
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let offsetX = (bounds.width - Self.contentWidth) / 2 + Self.barWidth / 2
        NSColor.labelColor.withAlphaComponent(0.95).setFill()
        for (i, cx) in Self.barCenters.enumerated() {
            let h = displayed[i]
            let rect = NSRect(
                x: offsetX + cx - Self.barWidth / 2,
                y: (bounds.height - h) / 2,
                width: Self.barWidth,
                height: h)
            NSBezierPath(roundedRect: rect, xRadius: Self.barWidth / 2,
                         yRadius: Self.barWidth / 2).fill()
        }
    }
}
