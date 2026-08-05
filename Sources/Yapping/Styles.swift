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
    /// Spoken formatting commands ("new paragraph") honored in this style.
    var voiceCommands: Bool = true
    /// BCP-47 target language; empty inherits the global default.
    var targetLanguage: String = ""

    init(id: UUID = UUID(), name: String, appPatterns: [String], prompt: String,
         verbatim: Bool = false, voiceCommands: Bool = true, targetLanguage: String = "") {
        self.id = id
        self.name = name
        self.appPatterns = appPatterns
        self.prompt = prompt
        self.verbatim = verbatim
        self.voiceCommands = voiceCommands
        self.targetLanguage = targetLanguage
    }

    /// Hand-written so a style saved by an older build still decodes: the
    /// synthesized initializer throws on a missing key even when the property
    /// has a default, which would cost the user every prompt they wrote.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Style"
        appPatterns = try c.decodeIfPresent([String].self, forKey: .appPatterns) ?? []
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        verbatim = try c.decodeIfPresent(Bool.self, forKey: .verbatim) ?? false
        voiceCommands = try c.decodeIfPresent(Bool.self, forKey: .voiceCommands) ?? true
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? ""
    }

    /// Dictating prompts to AI assistants: terse, technical, no fluff.
    /// (Terminal-based agents are covered by the verbatim Code style.)
    static let promptPreset = Style(
        name: "Prompt",
        appPatterns: ["com.anthropic.claudefordesktop", "com.openai.chat", "perplexity"],
        prompt: "This is a prompt for an AI assistant. Keep it terse and imperative. Preserve technical tokens exactly: file paths, code identifiers, flags, URLs, version numbers. Remove filler but never soften or pad the request."
    )

    static let defaults: [Style] = [
        promptPreset,
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
