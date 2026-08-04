import AppKit

/// The Dock companion while you talk: the yapping logo bars dancing with
/// your voice, and/or a live line of what the recognizer heard so far.
/// Both elements are optional per user settings; the panel shows whichever
/// are enabled and fades out on release.
final class WaveformHUD {
    private static let panelSize = NSSize(width: 560, height: 96)
    private static let waveSize = NSSize(width: 168, height: 46)
    private static let pillHeight: CGFloat = 30
    private static let pillMaxWidth: CGFloat = 520

    private var panel: NSPanel?
    private var waveView: WaveformView?
    private var pill: NSVisualEffectView?
    private var label: NSTextField?
    private var barsVisible = true

    /// Fade in and start dancing (call on fn-press).
    func show(bars: Bool = true) {
        DispatchQueue.main.async {
            if self.panel == nil { self.makePanel() }
            self.barsVisible = bars
            self.waveView?.isHidden = !bars
            self.setTextNow("")
            self.position()
            self.waveView?.reset()
            if bars { self.waveView?.start() }
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

    /// Live transcript so far; thread-safe. The newest words stay visible
    /// (head truncation) and the pill hugs the text width.
    func setText(_ text: String) {
        DispatchQueue.main.async { self.setTextNow(text) }
    }

    private func setTextNow(_ text: String) {
        guard let pill, let label else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pill.isHidden = true
            label.stringValue = ""
            return
        }
        label.stringValue = trimmed
        let textWidth = label.attributedStringValue.size().width
        let width = min(Self.pillMaxWidth, textWidth + 28)
        let y = barsVisible ? Self.waveSize.height + 8 : 8
        pill.frame = NSRect(
            x: (Self.panelSize.width - width) / 2, y: y,
            width: width, height: Self.pillHeight)
        label.frame = pill.bounds.insetBy(dx: 12, dy: 0)
        pill.isHidden = false
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

        let wave = WaveformView(frame: NSRect(
            origin: NSPoint(x: (Self.panelSize.width - Self.waveSize.width) / 2, y: 0),
            size: Self.waveSize))
        panel.contentView?.addSubview(wave)

        let pill = NSVisualEffectView()
        pill.material = .hudWindow
        pill.blendingMode = .behindWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Self.pillHeight / 2
        pill.layer?.masksToBounds = true
        pill.isHidden = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.alignment = .center
        pill.addSubview(label)
        panel.contentView?.addSubview(pill)

        waveView = wave
        self.pill = pill
        self.label = label
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
    private static let restHeights: [CGFloat] = [4, 9, 15, 7, 11, 3].map { $0 * 1.5 }
    private static let barWidth: CGFloat = 5
    private static let maxHeight: CGFloat = 36
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
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        let span = bounds.width * 0.52
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
