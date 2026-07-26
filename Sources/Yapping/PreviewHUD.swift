import AppKit

/// Opt-in floating panel showing the live transcript while fn is held.
/// Finalized text renders solid; the volatile tail renders dimmed and is
/// replaced wholesale as recognition refines it.
final class PreviewHUD {
    private var panel: NSPanel?
    private var label: NSTextField?

    private func makePanel() -> NSPanel {
        let width: CGFloat = 560
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let text = NSTextField(wrappingLabelWithString: "")
        text.frame = effect.bounds.insetBy(dx: 16, dy: 12)
        text.autoresizingMask = [.width, .height]
        text.font = .systemFont(ofSize: 14)
        text.isEditable = false
        text.isBezeled = false
        text.drawsBackground = false
        text.maximumNumberOfLines = 3
        text.cell?.truncatesLastVisibleLine = true
        effect.addSubview(text)
        panel.contentView?.addSubview(effect)

        label = text
        return panel
    }

    func show() {
        if panel == nil { panel = makePanel() }
        update(finalized: "", volatile: "")
        position()
        panel?.orderFrontRegardless()
    }

    func update(finalized: String, volatile: String) {
        DispatchQueue.main.async {
            guard let label = self.label else { return }
            let output = NSMutableAttributedString()
            output.append(NSAttributedString(
                string: finalized,
                attributes: [.foregroundColor: NSColor.labelColor,
                             .font: NSFont.systemFont(ofSize: 14)]))
            output.append(NSAttributedString(
                string: volatile,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.systemFont(ofSize: 14)]))
            if output.length == 0 {
                output.append(NSAttributedString(
                    string: "Listening...",
                    attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                                 .font: NSFont.systemFont(ofSize: 14)]))
            }
            label.attributedStringValue = output
        }
    }

    func hide() {
        DispatchQueue.main.async { self.panel?.orderOut(nil) }
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 80))
    }
}
