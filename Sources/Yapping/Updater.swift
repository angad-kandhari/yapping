import AppKit

enum UpdaterError: Error, LocalizedError {
    case noAsset
    case badDownload
    case signatureRejected
    case notInstalled
    case notWritable

    var errorDescription: String? {
        switch self {
        case .noAsset:
            return "This release has no downloadable build attached."
        case .badDownload:
            return "The update could not be downloaded."
        case .signatureRejected:
            return "The downloaded update failed signature verification, so it was not installed."
        case .notInstalled:
            return "In-place updates only work when running from Yapping.app."
        case .notWritable:
            return "Yapping.app is not writable here; download the update manually."
        }
    }
}

/// In-app updates, no framework: download the release zip from GitHub,
/// verify Apple's signature chain says it is ours, then hand a five-line
/// shell script the job of swapping the bundle and relaunching once this
/// process exits. URLSession downloads carry no quarantine flag, so the
/// updated app launches without Gatekeeper friction.
enum Updater {
    /// The one team every legitimate release is signed by. A download that
    /// does not verify against Apple's anchor with this team is discarded.
    private static let team = "W64YC3NG4K"

    static func install(
        _ release: Release, progress: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let zipURL = release.zipURL else { throw UpdaterError.noAsset }
        let dest = Bundle.main.bundleURL
        guard dest.pathExtension == "app" else { throw UpdaterError.notInstalled }
        guard FileManager.default.isWritableFile(
            atPath: dest.deletingLastPathComponent().path) else {
            throw UpdaterError.notWritable
        }

        await MainActor.run { progress("Downloading Yapping \(release.version)...") }
        let (download, response) = try await URLSession.shared.download(from: zipURL)
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        NetLog.shared.record(zipURL, purpose: "update download", ok: ok)
        guard ok else {
            throw UpdaterError.badDownload
        }

        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("yapping-update-\(release.version)")
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", "-xk", download.path, stage.path)
        guard let newApp = try FileManager.default
            .contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.badDownload
        }

        await MainActor.run { progress("Verifying signature...") }
        do {
            try run("/usr/bin/codesign", "--verify", "--deep", "--strict",
                    "-R=anchor apple generic and certificate leaf[subject.OU] = \(team)",
                    newApp.path)
        } catch {
            Log.error("update rejected, signature did not verify: \(error)")
            throw UpdaterError.signatureRejected
        }

        await MainActor.run { progress("Installing and relaunching...") }
        Log.info("updating to \(release.version); handing off swap and relaunch")
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(quoted(dest.path)) && /usr/bin/ditto \(quoted(newApp.path)) \(quoted(dest.path)) && /usr/bin/open \(quoted(dest.path))
        /bin/rm -rf \(quoted(stage.path))
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = ["-c", script]
        try helper.run()
        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct ToolFailure: Error, LocalizedError {
        let tool: String
        let status: Int32
        var errorDescription: String? { "\(tool) exited with status \(status)" }
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolFailure(
                tool: (tool as NSString).lastPathComponent,
                status: process.terminationStatus)
        }
    }
}
