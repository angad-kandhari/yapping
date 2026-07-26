import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum ListenError: Error, LocalizedError {
    case tapCreation(OSStatus)
    case aggregateCreation(OSStatus)
    case format
    case ioProc(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreation(let s):
            return "Could not tap system audio (\(s)). Check System Settings, Privacy & Security, System Audio Recording Only."
        case .aggregateCreation(let s): return "Audio device setup failed (\(s))."
        case .format: return "Unsupported system audio format."
        case .ioProc(let s): return "Audio capture failed to start (\(s))."
        }
    }
}

/// Captures everything the Mac plays via a Core Audio process tap.
///
/// Chosen over ScreenCaptureKit deliberately: the tap prompts under the
/// gentler "System Audio Recording Only" privacy category and has no
/// monthly re-approval. Hard-won rules encoded below:
/// - the aggregate device MUST include a real output sub-device;
///   a tap-only aggregate silently produces zero samples
/// - read with an IOProc; AVAudioEngine claims to accept the aggregate
///   but keeps reading the default input instead
/// - the aggregate is private so our own device-change handling (and
///   other apps') never reacts to it
final class ProcessTapSource {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "yapping-listen-tap")
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var tapFormat: AVAudioFormat?

    /// Starts capture; the first call ever triggers the system permission
    /// prompt. Returns a stream of PCM buffers in the tap's native format.
    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw ListenError.tapCreation(status)
        }
        tapID = tap

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "yapping-listen",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr, agg != kAudioObjectUnknown else {
            cleanupTap()
            throw ListenError.aggregateCreation(status)
        }
        aggregateID = agg

        guard var asbd = Self.tapStreamDescription(tapID),
              let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw ListenError.format
        }
        tapFormat = format

        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        continuation = cont

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let format = self.tapFormat else { return }
            // The HAL owns this memory only for the callback; deep-copy
            guard let source = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData, deallocator: nil),
                source.frameLength > 0,
                let copy = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: source.frameLength)
            else { return }
            copy.frameLength = source.frameLength
            let channels = Int(format.channelCount)
            if let src = source.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<channels {
                    dst[ch].update(from: src[ch], count: Int(source.frameLength))
                }
            }
            self.continuation?.yield(copy)
        }
        guard status == noErr, procID != nil else {
            cleanup()
            throw ListenError.ioProc(status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            cleanup()
            throw ListenError.ioProc(status)
        }
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        cleanup()
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        cleanupTap()
    }

    private func cleanupTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Core Audio property plumbing

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw ListenError.aggregateCreation(status) }

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw ListenError.aggregateCreation(status) }
        return uid as String
    }

    private static func tapStreamDescription(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        return status == noErr ? asbd : nil
    }
}
