import Foundation
import CoreGraphics

/// Hold-to-talk gesture detection on the Globe/fn key.
///
/// Uses a listen-only CGEventTap watching flagsChanged for keycode 63 with
/// the SecondaryFn mask. A listen-only tap cannot swallow the key press, so
/// the user should set System Settings -> Keyboard -> "Press globe key to"
/// -> Do Nothing.
///
/// Callbacks fire on the tap thread and must not block:
/// - onPress: fn went down (hold begins)
/// - onDiscard: Esc was pressed while fn was held (explicit throw-away)
/// - onCancel: any other key was pressed while fn was held (fn+arrow etc.)
/// - onRelease: fn came back up (always fired at the end of a hold)
final class FnKeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Esc while fn is held: the user explicitly asked to discard.
    var onDiscard: (() -> Void)?
    /// Esc pressed while fn is NOT held; used to end hands-free sessions.
    var onEscape: (() -> Void)?

    private static let fnKeycode: Int64 = 63  // kVK_Function
    private var held = false
    private var combo = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "fn-tap"
        t.start()
        thread = t
    }

    func stop() {
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
        thread = nil
    }

    private func run() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        var attempts = 0
        var created: CFMachPort?
        while created == nil {
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                    monitor.handle(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            if created == nil {
                if attempts == 0 {
                    Log.info("waiting for Input Monitoring permission: enable 'Yapping' under System Settings -> Privacy & Security -> Input Monitoring, then relaunch")
                    _ = CGRequestListenEventAccess()
                }
                attempts += 1
                Thread.sleep(forTimeInterval: 5)
            }
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: created!, enable: true)
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS silently disables slow taps; re-arm or the hotkey dies
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        switch type {
        case .flagsChanged:
            // fn+arrow keys carry the SecondaryFn flag on their own keycodes;
            // only keycode 63 marks the fn key itself going down or up
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keycode == Self.fnKeycode else { return }
            let fnDown = event.flags.contains(.maskSecondaryFn)
            if fnDown && !held {
                held = true
                combo = false
                onPress?()
            } else if !fnDown && held {
                held = false
                onRelease?()
            }
        case .keyDown:
            if held && !combo {
                // Esc explicitly discards. Any other fn+<key> is a shortcut
                // (fn+arrow = page up, ...), not a hold, so it cancels the
                // paste, but the words are worth keeping: the caller decides.
                combo = true
                if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                    onDiscard?()
                } else {
                    onCancel?()
                }
            } else if !held,
                      event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                onEscape?()
            }
        default:
            break
        }
    }
}
