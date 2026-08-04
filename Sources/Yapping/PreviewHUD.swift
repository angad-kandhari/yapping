import AppKit

/// The recording pill above the Dock: one capsule holding a status dot,
/// the dancing logo bars, the live transcript, elapsed time, and the
/// active style chip. It stays through processing (blue dot, frozen bars)
/// and flashes green when the text lands, then fades.
///
/// The pill is always click-through; esc is the only control, and the
/// pill says so. Which segments render is the user's choice: bars follow
/// `hudEnabled`, live text follows `livePreview`.
final class WaveformHUD {
    private static let panelSize = NSSize(width: 700, height: 56)
    private static let capsuleHeight: CGFloat = 40
    private static let maxTextWidth: CGFloat = 320
    private static let spacing: CGFloat = 10
    private static let hPad: CGFloat = 16

    private var panel: NSPanel?
    private var capsule: NSVisualEffectView?
    private var dot = StatusDotView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    private var waveView: WaveformView?
    private var textLabel: NSTextField?
    private var elapsedLabel: NSTextField?
    private var styleLabel: NSTextField?
    private var escLabel: NSTextField?

    private var startedAt = Date()
    private var maxHold: TimeInterval = 300
    private var showBars = true
    private var showText = true
    private var gotAudio = false
    private var processing = false
    private var ticker: Timer?
    private var processingTimeout: Timer?

    // MARK: - Session lifecycle

    /// Show the pill for a new dictation (call on fn-press).
    func begin(style: String?, startedAt: Date, maxHold: TimeInterval,
               showBars: Bool, showText: Bool) {
        DispatchQueue.main.async {
            if self.panel == nil { self.makePanel() }
            self.startedAt = startedAt
            self.maxHold = maxHold
            self.showBars = showBars
            self.showText = showText
            self.gotAudio = false
            self.processing = false
            self.processingTimeout?.invalidate()
            self.processingTimeout = nil

            self.dot.set(.starting)
            self.waveView?.isHidden = !showBars
            self.waveView?.reset()
            self.waveView?.setDimmed(false)
            if showBars { self.waveView?.start() }
            self.textLabel?.stringValue = ""
            self.textLabel?.isHidden = true
            self.elapsedLabel?.stringValue = "0:00"
            self.elapsedLabel?.isHidden = false
            self.elapsedLabel?.textColor = .tertiaryLabelColor
            self.setStyleChip(style)
            self.escLabel?.isHidden = true

            self.ticker?.invalidate()
            self.ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
                [weak self] _ in self?.tick()
            }
            self.relayout()
            self.position()
            self.panel?.alphaValue = 0
            self.panel?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.panel?.animator().alphaValue = 1
            }
        }
    }

    /// Recording ended; the pipeline is working. Bars freeze, dot goes
    /// blue. A hard timeout fades the pill if the pipeline hangs; the
    /// menu bar keeps showing the true state regardless.
    func setProcessing(_ detail: String) {
        DispatchQueue.main.async {
            guard self.panel?.isVisible == true else { return }
            self.processing = true
            self.dot.set(.processing)
            self.waveView?.stop()
            self.waveView?.setDimmed(true)
            if self.showText || self.textLabel?.stringValue.isEmpty == false {
                self.textLabel?.stringValue = detail
                self.textLabel?.isHidden = false
            }
            self.elapsedLabel?.isHidden = true
            self.escLabel?.isHidden = true
            self.ticker?.invalidate()
            self.ticker = nil
            self.relayout()
            self.processingTimeout?.invalidate()
            self.processingTimeout = Timer.scheduledTimer(
                withTimeInterval: 20, repeats: false
            ) { [weak self] _ in self?.hide() }
        }
    }

    /// The text landed: green flash, brief hold, fade.
    func finish() {
        DispatchQueue.main.async {
            guard self.panel?.isVisible == true else { return }
            self.processingTimeout?.invalidate()
            self.processingTimeout = nil
            self.dot.set(.done)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self.hide()
            }
        }
    }

    /// Fade out (cancel, failure, or settings turned off mid-hold).
    func hide() {
        DispatchQueue.main.async {
            self.ticker?.invalidate()
            self.ticker = nil
            self.processingTimeout?.invalidate()
            self.processingTimeout = nil
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

    /// Thread-safe: called from the audio tap thread. First level also
    /// flips the dot from "starting" to "recording": honest feedback that
    /// the mic is truly live.
    func pushLevel(_ level: Float) {
        DispatchQueue.main.async {
            if !self.gotAudio {
                self.gotAudio = true
                if !self.processing { self.dot.set(.recording) }
            }
            self.waveView?.push(level)
        }
    }

    /// Live transcript so far; thread-safe. Newest words stay visible.
    func setText(_ text: String) {
        DispatchQueue.main.async {
            guard self.showText, !self.processing else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.textLabel?.stringValue = trimmed
            self.textLabel?.isHidden = trimmed.isEmpty
            self.relayout()
        }
    }

    /// Mid-session chip change (double-tap upgrades to hands-free).
    func setStyleChip(_ text: String?) {
        DispatchQueue.main.async {
            let value = text?.lowercased() ?? ""
            self.styleLabel?.stringValue = value
            self.styleLabel?.isHidden = value.isEmpty
            self.relayout()
        }
    }

    // MARK: - Internals

    private func tick() {
        let elapsed = Date().timeIntervalSince(startedAt)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        elapsedLabel?.stringValue = String(format: "%d:%02d", minutes, seconds)
        // Turn accent when the safety stop approaches
        elapsedLabel?.textColor = (maxHold - elapsed) < 30
            ? Brand.accentNSColor : .tertiaryLabelColor
        if elapsed > 2, escLabel?.isHidden == true {
            escLabel?.isHidden = false
            relayout()
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

        let capsule = NSVisualEffectView()
        capsule.material = .hudWindow
        capsule.blendingMode = .behindWindow
        capsule.state = .active
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = Self.capsuleHeight / 2
        capsule.layer?.masksToBounds = true
        panel.contentView?.addSubview(capsule)

        let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 58, height: 28))
        capsule.addSubview(dot)
        capsule.addSubview(wave)

        func label(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.maximumNumberOfLines = 1
            capsule.addSubview(field)
            return field
        }
        let text = label(size: 13, weight: .medium, color: .labelColor)
        text.lineBreakMode = .byTruncatingHead
        let elapsed = label(size: 12, weight: .regular, color: .tertiaryLabelColor)
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let style = label(size: 11, weight: .semibold, color: .secondaryLabelColor)
        let esc = label(size: 10, weight: .regular, color: .tertiaryLabelColor)
        esc.stringValue = "esc to cancel"

        self.capsule = capsule
        waveView = wave
        textLabel = text
        elapsedLabel = elapsed
        styleLabel = style
        escLabel = esc
        self.panel = panel
    }

    /// Manual flow layout: visible segments left to right, capsule hugs
    /// its content, centered in the panel.
    private func relayout() {
        guard let capsule else { return }
        var segments: [(NSView, CGFloat)] = [(dot, 8)]
        if let waveView, !waveView.isHidden {
            segments.append((waveView, 58))
        }
        if let textLabel, !textLabel.isHidden {
            let width = min(textLabel.attributedStringValue.size().width + 4, Self.maxTextWidth)
            segments.append((textLabel, width))
        }
        if let elapsedLabel, !elapsedLabel.isHidden {
            segments.append((elapsedLabel, elapsedLabel.attributedStringValue.size().width + 4))
        }
        if let styleLabel, !styleLabel.isHidden {
            segments.append((styleLabel, min(styleLabel.attributedStringValue.size().width + 4, 120)))
        }
        if let escLabel, !escLabel.isHidden {
            segments.append((escLabel, escLabel.attributedStringValue.size().width + 4))
        }

        let content = segments.reduce(0) { $0 + $1.1 } + CGFloat(segments.count - 1) * Self.spacing
        let capsuleWidth = content + Self.hPad * 2
        capsule.frame = NSRect(
            x: (Self.panelSize.width - capsuleWidth) / 2,
            y: (Self.panelSize.height - Self.capsuleHeight) / 2,
            width: capsuleWidth, height: Self.capsuleHeight)

        var x = Self.hPad
        for (view, width) in segments {
            let height = view === waveView ? 28 : view.fittingSize.height
            let viewHeight = view === dot ? 8 : height
            view.frame = NSRect(
                x: x, y: (Self.capsuleHeight - viewHeight) / 2,
                width: width, height: viewHeight)
            x += width + Self.spacing
        }
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame  // excludes the Dock
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 12))
    }
}

/// The state dot: gray pulse while the mic spins up, accent while
/// recording, blue while processing, green when the text has landed.
private final class StatusDotView: NSView {
    private var color: NSColor = .tertiaryLabelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ state: WaveformHUDDotState) {
        switch state {
        case .starting: color = .tertiaryLabelColor; pulse(true)
        case .recording: color = Brand.accentNSColor; pulse(true)
        case .processing: color = .systemBlue; pulse(false)
        case .done: color = .systemGreen; pulse(false)
        }
        needsDisplay = true
    }

    private func pulse(_ on: Bool) {
        layer?.removeAnimation(forKey: "pulse")
        guard on else { layer?.opacity = 1; return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.35
        anim.duration = 0.8
        anim.autoreverses = true
        anim.repeatCount = .infinity
        layer?.add(anim, forKey: "pulse")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

enum WaveformHUDDotState { case starting, recording, processing, done }

/// The six logo bars, scaled down to live inside the pill: they grow in
/// from nothing, breathe while you pause, surge with your voice.
private final class WaveformView: NSView {
    // Logo geometry from Brand.barHeights, scaled for the 28 pt row
    private static let gridCenters: [CGFloat] = [0, 3.5, 7, 10.5, 14, 17.5]
    private static let gridSpan: CGFloat = 17.5
    private static let restHeights: [CGFloat] = Brand.barHeights.map { $0 * 1.1 }
    private static let barWidth: CGFloat = 3.5
    private static let maxHeight: CGFloat = 24
    private static let gain: Float = 85
    /// Per-bar breathing phase so silence still looks alive, never frozen
    private static let phases: [CGFloat] = [0.0, 1.1, 2.3, 3.6, 4.2, 5.5]

    private var levels: [Float] = Array(repeating: 0, count: 6)
    private var displayed: [CGFloat] = Array(repeating: 0, count: 6)
    private var timer: Timer?
    private var dimmed = false

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

    func setDimmed(_ value: Bool) {
        dimmed = value
        needsDisplay = true
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
        let span = bounds.width * 0.9
        let scaleX = span / Self.gridSpan
        let left = (bounds.width - span) / 2
        // labelColor adapts to the pill's material in light and dark
        NSColor.labelColor.withAlphaComponent(dimmed ? 0.3 : 1).setFill()
        for (i, gx) in Self.gridCenters.enumerated() {
            let h = max(Self.barWidth, min(displayed[i], bounds.height - 2))
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
