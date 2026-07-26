import AppKit

/// The Dock companion. Two states:
/// - idle: a tiny glass sliver sitting just above the Dock, barely there
/// - listening: on fn-hold it blooms into a wide, short pill where the
///   yapping bars dance with your voice; shrinks back on release
///
/// Uses the system Liquid Glass (NSGlassEffectView, macOS 26) so it matches
/// the OS look in light and dark; falls back to the classic HUD material.
final class WaveformHUD {
    // Panel is always active-size; the glass pill animates inside it
    private static let panelSize = NSSize(width: 220, height: 48)
    private static let idleFrame = NSRect(x: (220 - 64) / 2, y: 0, width: 64, height: 9)
    private static let activeFrame = NSRect(x: 10, y: 0, width: 200, height: 42)

    private var panel: NSPanel?
    private var glass: NSView?
    private var idleBar: ThemedCapsule?
    private var waveView: WaveformView?
    private var visible = false

    /// Show the idle sliver (call at launch and on release).
    func showIdle() {
        DispatchQueue.main.async {
            self.ensureVisible()
            self.waveView?.stop()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                self.setPillFrame(Self.idleFrame)
                self.waveView?.animator().alphaValue = 0
                self.idleBar?.animator().alphaValue = 1
            }
        }
    }

    /// Bloom into the listening pill (call on fn-press).
    func showActive() {
        DispatchQueue.main.async {
            self.ensureVisible()
            self.waveView?.reset()
            self.waveView?.start()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.setPillFrame(Self.activeFrame)
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

    private func ensureVisible() {
        if panel == nil { makePanel() }
        if !visible {
            position()
            panel?.alphaValue = 1
            panel?.orderFrontRegardless()
            visible = true
        }
    }

    private func setPillFrame(_ frame: NSRect) {
        glass?.animator().frame = frame
        setCornerRadius(frame.height / 2)
    }

    private func setCornerRadius(_ radius: CGFloat) {
        if let glassEffect = glass as? NSGlassEffectView {
            glassEffect.cornerRadius = radius
        } else {
            glass?.layer?.cornerRadius = radius
        }
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
        // No forced appearance: the glass follows the system theme

        // Content shared by both states; frames track the pill via autoresize
        let content = NSView(frame: NSRect(origin: .zero, size: Self.idleFrame.size))

        let idleBar = ThemedCapsule(frame: content.bounds.insetBy(dx: 1, dy: 1))
        idleBar.autoresizingMask = [.width, .height]
        content.addSubview(idleBar)

        let wave = WaveformView(frame: content.bounds)
        wave.autoresizingMask = [.width, .height]
        wave.alphaValue = 0
        content.addSubview(wave)

        let glass: NSView
        if let liquid = Self.makeGlassView() {
            liquid.frame = Self.idleFrame
            liquid.contentView = content
            content.frame = liquid.bounds
            glass = liquid
        } else {
            let effect = NSVisualEffectView(frame: Self.idleFrame)
            effect.material = .hudWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            content.frame = effect.bounds
            effect.addSubview(content)
            content.autoresizingMask = [.width, .height]
            glass = effect
        }

        panel.contentView?.addSubview(glass)
        self.glass = glass
        self.idleBar = idleBar
        self.waveView = wave
        self.panel = panel
        setCornerRadius(Self.idleFrame.height / 2)
    }

    private static func makeGlassView() -> NSGlassEffectView? {
        // Liquid Glass ships with macOS 26; keep a runtime guard anyway so
        // a future SDK change degrades to the classic material, not a crash
        guard NSClassFromString("NSGlassEffectView") != nil else { return nil }
        return NSGlassEffectView(frame: .zero)
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame  // excludes the Dock
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 10))
    }
}

/// The idle sliver's fill; follows the system theme via labelColor.
private final class ThemedCapsule: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
    }
}

/// The six logo bars, stretched wide and kept short, eased at 30 fps.
/// Draws centered for whatever size it currently is, so it stays true
/// through the bloom animation.
private final class WaveformView: NSView {
    // Logo bar centers on the 24-grid, normalized to start at zero
    private static let gridCenters: [CGFloat] = [0, 3.5, 7, 10.5, 14, 17.5]
    private static let gridSpan: CGFloat = 17.5
    private static let restHeights: [CGFloat] = [4, 9, 15, 7, 11, 3].map { $0 * 1.5 }
    private static let barWidth: CGFloat = 5
    private static let maxHeight: CGFloat = 30
    private static let gain: Float = 80

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

    override var frame: NSRect {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Spread the bars across ~70% of the current width, dead center
        let span = bounds.width * 0.7
        let scaleX = span / Self.gridSpan
        let left = (bounds.width - span) / 2
        NSColor.labelColor.withAlphaComponent(0.95).setFill()
        for (i, gx) in Self.gridCenters.enumerated() {
            let h = min(displayed[i], bounds.height - 6)
            let rect = NSRect(
                x: left + gx * scaleX - Self.barWidth / 2,
                y: (bounds.height - h) / 2,
                width: Self.barWidth,
                height: h)
            NSBezierPath(roundedRect: rect, xRadius: Self.barWidth / 2,
                         yRadius: Self.barWidth / 2).fill()
        }
    }
}
