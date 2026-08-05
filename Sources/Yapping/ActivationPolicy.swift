import AppKit

/// yapping hides from the Dock until it has a window worth managing, then
/// becomes a normal app so it gets a Dock icon, cmd-Tab, and a visible menu
/// bar. It goes back to hiding when the last window closes.
///
/// The hard constraint: dictation pastes into whatever app was frontmost, so
/// a policy switch must never happen between the key press and the paste.
/// Switching to .accessory while frontmost makes macOS activate the next app,
/// which would pull focus away from the paste target at the worst moment. So
/// while a session is running this only records what it wants and acts later.
///
/// Deliberately not generic: living inside UtilityWindow<Content> would give
/// one counter per specialization, which is five independent counters and a
/// silent bug.
enum ActivationPolicy {
    @MainActor private static var openWindows = 0
    @MainActor private static var dictating = false

    static func windowOpened() {
        onMain {
            openWindows += 1
            apply()
        }
    }

    static func windowClosed() {
        onMain {
            openWindows = max(0, openWindows - 1)
            apply()
        }
    }

    static func sessionBegan() {
        onMain { dictating = true }
    }

    /// Called from the end of the dictation pipeline, which is not main
    /// isolated, hence the hop.
    static func sessionEnded() {
        onMain {
            dictating = false
            apply()
        }
    }

    /// True while a dictation is in flight. Diagnostics refuses to open a
    /// second audio engine during one.
    @MainActor
    static var isDictating: Bool { dictating }

    @MainActor
    private static func apply() {
        guard !dictating else { return }  // queued; sessionEnded applies it
        let wanted: NSApplication.ActivationPolicy = openWindows > 0 ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { body() }
        }
    }
}
