import Foundation

/// The receipts behind the privacy promise: every network touch the app
/// makes, in order, kept for the session and shown in Settings > About.
/// An empty list after a day of dictating is the whole point.
struct NetEvent: Identifiable {
    let id = UUID()
    let date: Date
    let host: String
    let purpose: String
    let ok: Bool
}

final class NetLog: ObservableObject {
    static let shared = NetLog()
    @Published private(set) var events: [NetEvent] = []

    private init() {}

    func record(_ url: URL?, purpose: String, ok: Bool) {
        let host = url?.host ?? "unknown"
        Log.info("net: \(host) (\(purpose)) \(ok ? "ok" : "failed")")
        DispatchQueue.main.async {
            self.events.insert(
                NetEvent(date: Date(), host: host, purpose: purpose, ok: ok), at: 0)
            if self.events.count > 50 {
                self.events.removeLast(self.events.count - 50)
            }
        }
    }
}
