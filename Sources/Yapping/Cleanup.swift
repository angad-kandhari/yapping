import Foundation

/// Optional local LLM polish via Ollama. Falls back to the raw transcript on
/// any failure or suspicious output; the user's words are never lost.
enum Cleanup {
    static var host: String { ConfigStore.shared.ollamaHost }
    static var model: String { ConfigStore.shared.ollamaModel }

    private static let prompt = """
    You clean up dictated text. You will be given a raw speech transcription. \
    Return ONLY the cleaned text - no preamble, no quotes, no markdown, no explanation.

    Rules:
    - Remove filler words (um, uh, like, you know) and false starts
    - Fix grammar, punctuation, capitalization, and obvious transcription errors
    - Preserve the speaker's wording, meaning, tone, and sentence order
    - Do NOT summarize, restructure, add, or omit content
    - If the speaker corrects themselves (says "scratch that" or restates a sentence), keep only the corrected final version
    - Never use em dashes; use commas, periods, or parentheses instead
    - If the text is already clean, return it unchanged
    """

    static func polish(
        _ text: String, style: Style? = nil, fieldContext: String? = nil
    ) async -> String {
        guard ConfigStore.shared.cleanupEnabled else { return text }
        guard await isUp() else { return text }
        var systemPrompt = prompt
        let words = ConfigStore.shared.dictionary
        if !words.isEmpty {
            systemPrompt += "\n- Prefer these exact spellings when they appear: "
                + words.joined(separator: ", ")
        }
        if let style, !style.prompt.isEmpty {
            systemPrompt += "\n\nStyle for this app (\(style.name)): \(style.prompt)"
        }
        if let fieldContext, !fieldContext.isEmpty {
            systemPrompt += """


            The user is dictating into a field that already contains the \
            following text. Match its tone, vocabulary, and formatting. Do \
            not repeat or reference it in your output:
            ---
            \(fieldContext.suffix(1500))
            ---
            """
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "stream": false,
            "think": false,
            "keep_alive": -1,
            "options": ["temperature": 0.3, "num_predict": max(500, text.count / 2)],
        ]
        guard let url = URL(string: "\(host)/api/chat"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return text }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let message = json["message"] as? [String: Any],
              var cleaned = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return text }

        // Reasoning models sometimes leak think tags; strip as a backstop
        cleaned = cleaned.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // No em dashes in output, ever (user preference)
        cleaned = cleaned.replacingOccurrences(
            of: "\\s*[\u{2014}\u{2013}]\\s*", with: ", ", options: .regularExpression
        )

        // Cleanup only ever shortens or lightly edits. Much shorter means a
        // summary or refusal; much longer means leaked chain-of-thought or
        // commentary. Either way the raw words are safer.
        let lower = Int(0.3 * Double(text.count))
        let upper = Int(1.5 * Double(text.count)) + 40
        guard !cleaned.isEmpty, cleaned.count >= lower, cleaned.count <= upper else {
            return text
        }
        return cleaned
    }

    /// Voice editing: apply a spoken instruction to selected text.
    /// Returns nil on any failure so the caller can abort instead of
    /// destroying the selection.
    static func rewrite(selection: String, instruction: String) async -> String? {
        guard await isUp() else { return nil }
        let systemPrompt = """
        You edit text. Apply the spoken instruction to the given text. \
        Return ONLY the edited text - no preamble, no quotes, no commentary. \
        Never use em dashes; use commas, periods, or parentheses instead. \
        Preserve everything the instruction does not ask you to change.
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Instruction: \(instruction)\n\nText:\n\(selection)"],
            ],
            "stream": false,
            "think": false,
            "keep_alive": -1,
            "options": ["temperature": 0.3,
                        "num_predict": max(600, selection.count)],
        ]
        guard let url = URL(string: "\(host)/api/chat"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let message = json["message"] as? [String: Any],
              var edited = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }

        edited = edited.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        edited = edited.replacingOccurrences(
            of: "\\s*[\u{2014}\u{2013}]\\s*", with: ", ", options: .regularExpression)

        // Edits can legitimately shorten or lengthen; guard only the absurd
        guard !edited.isEmpty, edited.count <= selection.count * 4 + 400 else {
            return nil
        }
        return edited
    }

    /// Public reachability check (used by the setup assistant).
    static func reachable() async -> Bool { await isUp() }

    /// Fast health check so a stopped Ollama costs ~1s, not a long timeout.
    private static func isUp() async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        let result = try? await URLSession.shared.data(for: request)
        return (result?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    /// Load the model into memory at startup so the first polish is instant.
    static func warmUp() async {
        guard await isUp() else {
            NSLog("ollama not running; cleanup will fall back to raw transcripts")
            return
        }
        let body: [String: Any] = [
            "model": model, "prompt": "hi", "stream": false, "think": false,
            "keep_alive": -1, "options": ["num_predict": 1],
        ]
        guard let url = URL(string: "\(host)/api/generate"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
        NSLog("ollama '%@' warm", model)
    }
}
