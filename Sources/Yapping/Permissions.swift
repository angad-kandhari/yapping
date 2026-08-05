import AVFoundation
import ApplicationServices
import Foundation

/// The four grants yapping needs, in one place. Onboarding and Diagnostics
/// both ask, and two copies of these checks would drift apart.
enum Permissions {
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var inputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    /// The globe key must be set to "Do Nothing" or macOS eats the press
    /// before the event tap sees it.
    static var globeKeyFree: Bool {
        CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString
        ) as? Int == 0
    }

    static var all: Bool {
        microphone && inputMonitoring && accessibility && globeKeyFree
    }
}
