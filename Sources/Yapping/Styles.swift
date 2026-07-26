import Foundation

/// A dictation style: which apps it applies to and how cleanup should write.
/// Styles are fully user-editable; nothing about the rewriting is hidden.
struct Style: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Bundle-id substrings, matched case-insensitively against the
    /// frontmost app ("com.tinyspeck.slackmacgap", "com.apple.mail", ...).
    var appPatterns: [String]
    /// Extra writing instructions appended to the cleanup prompt.
    var prompt: String
    /// Verbatim styles skip LLM cleanup entirely (terminals, editors).
    var verbatim: Bool = false

    static let defaults: [Style] = [
        Style(
            name: "Casual",
            appPatterns: ["slack", "discord", "mobilesms", "messages", "whatsapp", "telegram"],
            prompt: "Casual chat message: keep it light, contractions are fine, drop trailing periods on short messages, never capitalize for formality's sake."
        ),
        Style(
            name: "Formal",
            appPatterns: ["com.apple.mail", "outlook", "airmail"],
            prompt: "Professional email prose: complete sentences, proper punctuation, courteous tone. Do not add greetings or signoffs that were not spoken."
        ),
        Style(
            name: "Code",
            appPatterns: ["terminal", "iterm", "com.microsoft.VSCode", "cursor", "warp", "ghostty", "xcode", "zed"],
            prompt: "",
            verbatim: true
        ),
    ]

    /// The style for a bundle id, or nil for the built-in default behavior.
    static func match(_ styles: [Style], bundleID: String?) -> Style? {
        guard let bundleID = bundleID?.lowercased() else { return nil }
        return styles.first { style in
            style.appPatterns.contains { !$0.isEmpty && bundleID.contains($0.lowercased()) }
        }
    }
}
