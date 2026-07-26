import AppKit

/// The Dock companion: just the yapping logo bars, floating above the Dock
/// while you talk. No pill, no background. They grow in when the hold
/// starts, breathe and dance with your voice, and fade out on release.
final class WaveformHUD {
    private static let panelSize = NSSize(width: 240, height: 64)

    private var panel: NSPanel?
    private var waveView: WaveformView?

    /// Fade in and start dancing (call on fn-press).
    func show() {
        DispatchQueue.main.async {
            if self.panel == nil { self.makePanel() }
            self.position()
            self.waveView?.reset()
            self.waveView?.start()
            self.panel?.alphaValue = 0
            self.panel?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.panel?.animator().alphaValue = 1
            }
        }
    }

    /// Fade out (call on release or when the setting is turned off).
    func hide() {
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel?.animator().alphaValue = 0
            }, completionHandler: {
                self.waveView?.stop()
                self.panel?.orderOut(nil)
            })
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

        let wave = WaveformView(frame: NSRect(origin: .zero, size: Self.panelSize))
        wave.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(wave)

        waveView = wave
        self.panel = panel
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame  // excludes the Dock
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 12))
    }
}

/// The six logo bars, free-floating: they grow in from nothing, breathe
/// while you pause, surge with your voice, at 60 fps with soft shadows so
/// they read on any wallpaper.
private final class WaveformView: NSView {
    // Logo geometry (24-grid), bar centers normalized to start at zero
    private static let gridCenters: [CGFloat] = [0, 3.5, 7, 10.5, 14, 17.5]
    private static let gridSpan: CGFloat = 17.5
    private static let restHeights: [CGFloat] = [4, 9, 15, 7, 11, 3].map { $0 * 2.2 }
    private static let barWidth: CGFloat = 7
    private static let maxHeight: CGFloat = 52
    private static let gain: Float = 85
    /// Per-bar breathing phase so silence still looks alive, never frozen
    private static let phases: [CGFloat] = [0.0, 1.1, 2.3, 3.6, 4.2, 5.5]

    private var levels: [Float] = Array(repeating: 0, count: 6)
    private var displayed: [CGFloat] = Array(repeating: 0, count: 6)
    private var timer: Timer?

    func reset() {
        levels = Array(repeating: 0, count: 6)
        // Bars grow in from nothing via the easing itself
        displayed = Array(repeating: 0, count: 6)
        needsDisplay = true
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
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
        let now = CACurrentMediaTime()
        for i in 0..<displayed.count {
            let breath = 0.82 + 0.18 * sin(CGFloat(now) * 2.4 + Self.phases[i])
            let rest = Self.restHeights[i] * breath
            let t = CGFloat(min(1, levels[i] * Self.gain))
            let target = rest + (Self.maxHeight - rest) * t
            displayed[i] += (target - displayed[i]) * 0.35
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        // Soft shadow keeps white bars legible on light wallpapers
        ctx.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        let span = bounds.width * 0.62
        let scaleX = span / Self.gridSpan
        let left = (bounds.width - span) / 2
        NSColor.white.setFill()
        for (i, gx) in Self.gridCenters.enumerated() {
            let h = max(Self.barWidth, min(displayed[i], bounds.height - 10))
            let rect = NSRect(
                x: left + gx * scaleX - Self.barWidth / 2,
                y: (bounds.height - h) / 2,
                width: Self.barWidth,
                height: h)
            NSBezierPath(roundedRect: rect, xRadius: Self.barWidth / 2,
                         yRadius: Self.barWidth / 2).fill()
        }
        ctx.restoreGraphicsState()
    }
}
