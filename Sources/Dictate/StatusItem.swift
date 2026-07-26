import AppKit

/// Menu bar indicator: mic icon when idle, a live waveform while recording,
/// an hourglass while transcribing.
final class StatusItem {
    enum State {
        case idle, recording, processing
    }

    private static let blocks: [Character] = ["\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
                                              "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}"]
    /// RMS to bar index scaling: normal speech RMS is roughly 0.01-0.1.
    private static let gain: Float = 80

    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "Hold \u{1F310} (fn) to talk", action: nil, keyEquivalent: "")
    private var levels: [Float] = Array(repeating: 0, count: 8)
    private var state: State = .idle
    private var timer: Timer?

    /// Template glyph from the icon pack; adapts to light/dark menu bars.
    /// Falls back to an emoji when running outside the app bundle.
    private let glyph: NSImage? = {
        guard let image = Bundle.main.image(forResource: "dictateTemplate") else { return nil }
        image.isTemplate = true
        return image
    }()

    init(onQuit: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        showGlyph()

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Dictate", action: #selector(MenuTarget.quit), keyEquivalent: "q")
        let target = MenuTarget(onQuit: onQuit)
        quit.target = target
        objc_setAssociatedObject(menu, "target", target, .OBJC_ASSOCIATION_RETAIN)
        menu.addItem(quit)
        item.menu = menu

        // Redraws the waveform while recording; no-op the rest of the time
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Thread-safe: called from the audio tap thread.
    func pushLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.levels.removeFirst()
            self.levels.append(level)
        }
    }

    func setState(_ state: State) {
        DispatchQueue.main.async {
            self.state = state
            switch state {
            case .idle:
                self.showGlyph()
                self.statusLine.title = "Hold \u{1F310} (fn) to talk"
            case .recording:
                self.levels = Array(repeating: 0, count: 8)
                self.item.button?.image = nil
                self.statusLine.title = "Listening..."
            case .processing:
                self.item.button?.image = nil
                self.item.button?.title = "\u{23F3}"
                self.statusLine.title = "Transcribing..."
            }
        }
    }

    private func showGlyph() {
        if let glyph {
            item.button?.title = ""
            item.button?.image = glyph
        } else {
            item.button?.image = nil
            item.button?.title = "\u{1F399}\u{FE0F}"
        }
    }

    private func tick() {
        guard state == .recording else { return }
        let wave = String(levels.map { level -> Character in
            let index = min(Self.blocks.count - 1, Int(level * Self.gain))
            return Self.blocks[max(0, index)]
        })
        item.button?.title = wave
    }
}

private final class MenuTarget: NSObject {
    private let onQuit: () -> Void
    init(onQuit: @escaping () -> Void) { self.onQuit = onQuit }
    @objc func quit() { onQuit() }
}
