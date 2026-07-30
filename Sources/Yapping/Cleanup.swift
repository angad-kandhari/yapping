import Foundation
import FoundationModels

/// Transcript polish via a local provider chain. Every path stays on this
/// Mac unless the user explicitly points the custom endpoint elsewhere:
/// - "apple": Apple's on-device Foundation Model (zero setup), falling
///   back to Ollama if Apple Intelligence is unavailable
/// - "ollama": local Ollama (the classic path)
/// - "custom": any OpenAI-compatible endpoint (LM Studio and friends)
/// All output passes the same guards; raw words always win on doubt.
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

    // MARK: - Public API

    static func polish(
        _ text: String, style: Style? = nil, fieldContext: String? = nil
    ) async -> String {
        guard ConfigStore.shared.cleanupEnabled else { return text }
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

        guard let raw = await chat(
            system: systemPrompt, user: text,
            maxTokens: max(500, text.count / 2)) else { return text }
        let cleaned = sanitize(raw)

        // Cleanup only ever shortens or lightly edits. Much shorter means a
        // summary or refusal; much longer means leaked reasoning or
        // commentary. Either way the raw words are safer.
        guard !cleaned.isEmpty,
              cleaned.count >= Int(0.3 * Double(text.count)),
              cleaned.count <= Int(1.5 * Double(text.count)) + 40 else {
            return text
        }
        return cleaned
    }

    /// Voice editing: apply a spoken instruction to selected text.
    /// Returns nil on any failure so the caller can abort instead of
    /// destroying the selection.
    static func rewrite(selection: String, instruction: String) async -> String? {
        let systemPrompt = """
        You edit text. Apply the spoken instruction to the given text. \
        Return ONLY the edited text - no preamble, no quotes, no commentary. \
        Never use em dashes; use commas, periods, or parentheses instead. \
        Preserve everything the instruction does not ask you to change.
        """
        guard let raw = await chat(
            system: systemPrompt,
            user: "Instruction: \(instruction)\n\nText:\n\(selection)",
            maxTokens: max(600, selection.count)) else { return nil }
        let edited = sanitize(raw)

        // Edits can legitimately shorten or lengthen; guard only the absurd
        guard !edited.isEmpty, edited.count <= selection.count * 4 + 400 else {
            return nil
        }
        return edited
    }

    /// Ollama reachability (used by the setup assistant).
    static func reachable() async -> Bool { await ollamaUp() }

    /// Warm whichever provider is configured so the first polish is instant.
    static func warmUp() async {
        switch ConfigStore.shared.cleanupProvider {
        case "apple":
            if case .available = SystemLanguageModel.default.availability {
                let session = LanguageModelSession(instructions: prompt)
                session.prewarm()
                Log.info("apple foundation model warm")
                return
            }
            Log.info("apple intelligence unavailable; will fall back to ollama")
            await warmOllama()
        case "custom":
            break  // nothing to warm; the endpoint manages its own models
        default:
            await warmOllama()
        }
    }

    // MARK: - Provider chain

    private static func chat(
        system: String, user: String, maxTokens: Int
    ) async -> String? {
        switch ConfigStore.shared.cleanupProvider {
        case "apple":
            if let out = await appleChat(system: system, user: user) { return out }
            // Apple Intelligence off or refused: try Ollama before giving up
            return await ollamaChat(system: system, user: user, maxTokens: maxTokens)
        case "custom":
            return await openAIChat(system: system, user: user, maxTokens: maxTokens)
        default:
            return await ollamaChat(system: system, user: user, maxTokens: maxTokens)
        }
    }

    private static func appleChat(system: String, user: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }
        do {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content
        } catch {
            // Includes safety refusals; the guards and fallbacks handle it
            Log.error("apple model cleanup failed: \(error)")
            return nil
        }
    }

    private static func ollamaChat(
        system: String, user: String, maxTokens: Int
    ) async -> String? {
        guard await ollamaUp() else { return nil }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
            "think": false,
            "keep_alive": -1,
            "options": ["temperature": 0.3, "num_predict": maxTokens],
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
              let content = message["content"] as? String else { return nil }
        return content
    }

    private static func openAIChat(
        system: String, user: String, maxTokens: Int
    ) async -> String? {
        let config = ConfigStore.shared
        let base = config.customBaseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty,
              let url = URL(string: base.hasSuffix("/")
                  ? base + "chat/completions"
                  : base + "/chat/completions") else { return nil }
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.3,
            "max_tokens": maxTokens,
        ]
        if !config.customModel.isEmpty { body["model"] = config.customModel }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.customKey.isEmpty {
            request.setValue("Bearer \(config.customKey)", forHTTPHeaderField: "Authorization")
        }

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    // MARK: - Shared helpers

    private static func sanitize(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reasoning models sometimes leak think tags; strip as a backstop
        cleaned = cleaned.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // No em dashes in output, ever (user preference)
        cleaned = cleaned.replacingOccurrences(
            of: "\\s*[\u{2014}\u{2013}]\\s*", with: ", ", options: .regularExpression)
        return cleaned
    }

    private static func ollamaUp() async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        let result = try? await URLSession.shared.data(for: request)
        return (result?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    private static func warmOllama() async {
        guard await ollamaUp() else {
            Log.info("ollama not running; cleanup will fall back to raw transcripts")
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
        Log.info("ollama '\(model)' warm")
    }
}
