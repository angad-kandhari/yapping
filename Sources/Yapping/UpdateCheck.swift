import AppKit
import Foundation

/// Lightweight update check against GitHub releases. No frameworks, no
/// background phoning home: it runs only when the user asks.
enum UpdateCheck {
    private static let releasesAPI =
        "https://api.github.com/repos/angad729/yapping/releases/latest"
    private static let releasesPage =
        "https://github.com/angad729/yapping/releases/latest"

    static func run() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "0"
        Task {
            guard let url = URL(string: releasesAPI),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                await MainActor.run {
                    AppDelegate.notify("Update check failed",
                                       body: "Could not reach GitHub. Try again later.")
                }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let newer = latest.compare(current, options: .numeric) == .orderedDescending
            await MainActor.run {
                if newer {
                    AppDelegate.notify("Yapping \(latest) is available",
                                       body: "You have \(current). Opening the release page.")
                    NSWorkspace.shared.open(URL(string: releasesPage)!)
                } else {
                    AppDelegate.notify("You are up to date",
                                       body: "Yapping \(current) is the latest release.")
                }
            }
        }
    }
}
