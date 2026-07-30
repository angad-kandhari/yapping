import AppKit
import Foundation

struct Release: Identifiable {
    let id: String
    let version: String
    let title: String
    let notes: String
    let publishedAt: Date?
    let url: URL?
    /// The Yapping-vX.Y.Z.zip asset, what the in-app updater installs.
    let zipURL: URL?
}

/// Update lookups against GitHub releases. Runs when the user opens the
/// Updates window, plus a quiet check at launch and once a day after (menu
/// bar apps run for weeks; a launch-only check goes stale). The GitHub
/// releases API is the only thing ever contacted.
enum UpdateCheck {
    static let releasesPage = URL(
        string: "https://github.com/angad-kandhari/yapping/releases")!
    private static let releasesAPI =
        "https://api.github.com/repos/angad-kandhari/yapping/releases?per_page=20"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// All releases newer than the running version, newest first.
    /// Empty array means up to date; nil means the check failed.
    static func newerReleases() async -> [Release]? {
        guard let url = URL(string: releasesAPI),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let current = currentVersion
        let dateParser = ISO8601DateFormatter()
        return json.compactMap { item -> Release? in
            guard let tag = item["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard version.compare(current, options: .numeric) == .orderedDescending
            else { return nil }
            let assets = item["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            return Release(
                id: tag,
                version: version,
                title: item["name"] as? String ?? tag,
                notes: item["body"] as? String ?? "",
                publishedAt: (item["published_at"] as? String)
                    .flatMap { dateParser.date(from: $0) },
                url: (item["html_url"] as? String).flatMap { URL(string: $0) },
                zipURL: (zip?["browser_download_url"] as? String).flatMap { URL(string: $0) })
        }
    }

    // Per-version bookkeeping so the user is nagged exactly once: the
    // system notification fires once per new version, and the menu bar dot
    // stays until they open the Updates window for that version.
    private static let seenKey = "updateSeenVersion"
    private static let notifiedKey = "updateNotifiedVersion"
    private static var latestFound: String?
    private static var timer: Timer?

    /// Quiet checks at launch and daily. `onBadge` runs on the main thread
    /// with true while a newer release exists that the user has not looked
    /// at yet; it drives the dots on the menu bar icon and menu item.
    static func startQuietChecks(onBadge: @escaping (Bool) -> Void) {
        let check = {
            Task {
                guard let newer = await newerReleases() else { return }
                await MainActor.run {
                    guard let latest = newer.first else {
                        // Up to date (they installed the update): clear all
                        latestFound = nil
                        onBadge(false)
                        return
                    }
                    latestFound = latest.version
                    let defaults = UserDefaults.standard
                    onBadge(defaults.string(forKey: seenKey) != latest.version)
                    if defaults.string(forKey: notifiedKey) != latest.version {
                        defaults.set(latest.version, forKey: notifiedKey)
                        AppDelegate.notify(
                            "Yapping \(latest.version) is available",
                            body: "Open Check for Updates in the menu to see what's new.")
                    }
                }
            }
        }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            check()
        }
    }

    /// The user opened the Updates window; stop badging this version.
    static func markSeen() {
        if let latestFound {
            UserDefaults.standard.set(latestFound, forKey: seenKey)
        }
    }
}
