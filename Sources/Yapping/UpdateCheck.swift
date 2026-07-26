import AppKit
import Foundation

struct Release: Identifiable {
    let id: String
    let version: String
    let title: String
    let notes: String
    let publishedAt: Date?
    let url: URL?
}

/// Update lookups against GitHub releases. Runs only when the user opens
/// the Updates window, plus one quiet check at launch. No other phoning home.
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
            return Release(
                id: tag,
                version: version,
                title: item["name"] as? String ?? tag,
                notes: item["body"] as? String ?? "",
                publishedAt: (item["published_at"] as? String)
                    .flatMap { dateParser.date(from: $0) },
                url: (item["html_url"] as? String).flatMap { URL(string: $0) })
        }
    }

    /// Quiet launch check: notify only when something newer exists.
    static func quietCheck() {
        Task {
            guard let newer = await newerReleases(), let latest = newer.first else { return }
            await MainActor.run {
                AppDelegate.notify(
                    "Yapping \(latest.version) is available",
                    body: "Open Check for Updates in the menu to see what's new.")
            }
        }
    }
}
