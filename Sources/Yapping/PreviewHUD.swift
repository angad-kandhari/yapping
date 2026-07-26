import AppKit

/// The yapping logo, big, dancing above the Dock while you talk.
///
/// A frosted pill fades in when the hold starts. The six brand bars sit at
/// their logo rest pose in silence and dance with the live mic level while
/// you speak. Fades out on release. No text, just the waveform.
final class WaveformHUD {
    private var panel: NSPanel?
    private var waveView: WaveformView?

    func show() {
        if panel == nil { makePanel() }
        position()
        waveView?.reset()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel?.animator().alphaValue = 1
        }
        waveView?.start()
    }

    func hide() {
        DispatchQueue.main.async {
            self.waveView?.stop()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel?.animator().alphaValue = 0
            }, completionHandler: {
                self.panel?.orderOut(nil)
            })
        }
    }

    /// Thread-safe: called from the audio tap thread.
    func pushLevel(_ level: Float) {
        DispatchQueue.main.async { self.waveView?.push(level) }
    }

    private func makePanel() {
        let size = NSSize(width: 96, height: 64)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = size.height / 2
        effect.layer?.masksToBounds = true

        let wave = WaveformView(frame: effect.bounds)
        wave.autoresizingMask = [.width, .height]
        effect.addSubview(wave)
        panel.contentView?.addSubview(effect)

        waveView = wave
        self.panel = panel
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame  // excludes the Dock
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 14))
    }
}

/// The six logo bars at 2.5x menu bar scale, eased at 30 fps.
private final class WaveformView: NSView {
    // Logo geometry (24-grid), scaled 2.5x, centered in the pill
    private static let scale: CGFloat = 2.5
    private static let barCenters: [CGFloat] = [3.5, 7, 10.5, 14, 17.5, 21].map { $0 * scale }
    private static let restHeights: [CGFloat] = [4, 9, 15, 7, 11, 3].map { $0 * scale }
    private static let barWidth: CGFloat = 2 * scale
    private static let maxHeight: CGFloat = 44
    private static let gain: Float = 80
    private static let contentWidth: CGFloat = 22 * scale + 2 * scale  // last center + bar

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
