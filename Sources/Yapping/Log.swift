import AppKit
import Foundation
import os

/// App-wide logging. Every line goes to the unified system log (Console.app)
/// and to a plain-text file anyone can attach to a bug report:
/// ~/Library/Logs/Yapping/yapping.log
///
/// The file exists because "it crashed when I connected my AirPods" is
/// undebuggable from a friend's machine: unified log entries expire fast and
/// need the reporter to know log(1). A text file survives, rotates at 1 MB,
/// and is one "Reveal Log File" click away in Settings > About.
enum Log {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Yapping/yapping.log")

    private static let system = Logger(subsystem: "com.angad.dictate", category: "app")
    private static let queue = DispatchQueue(label: "yapping-log", qos: .utility)
    private static var handle: FileHandle?
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Open the file (rotating first if large) and write a session header.
    /// Call once, before anything else logs.
    static func start() {
        queue.sync { openFile() }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("yapping \(version) starting on macOS \(os)")
    }

    /// Uncaught Objective-C exceptions (AVFoundation format asserts, mostly)
    /// die without a Swift catch ever running; get the reason and backtrace
    /// into the file first so a bug report can carry them.
    static func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            Log.error("uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            Log.error("backtrace:\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }
    }

    static func info(_ message: String) {
        system.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        system.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    /// Recent ERROR lines for the diagnostics panel. Opens its own read
    /// handle so it never touches the write handle held on `queue`.
    static func recentErrors(limit: Int = 50) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .filter { $0.contains("[ERROR]") }
            .suffix(limit)
            .map(String.init)
    }

    static func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // Synchronous so the crash handler's last lines land before the process
    // dies; the queue keeps audio-thread and main-thread writers ordered.
    private static func write(_ level: String, _ message: String) {
        queue.sync {
            guard let handle else { return }
            let line = "\(timestamp.string(from: Date())) [\(level)] \(message)\n"
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func openFile() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep exactly one previous generation so the log never grows unbounded
        let attributes = try? fm.attributesOfItem(atPath: fileURL.path)
        if let size = attributes?[.size] as? UInt64, size > 1_000_000 {
            let previous = dir.appendingPathComponent("yapping.log.1")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: fileURL, to: previous)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }
}
