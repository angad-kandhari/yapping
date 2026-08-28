import Foundation

/// How hard cleanup is allowed to push on the speaker's sentences.
///
/// The polish prompt has always asked the model to fix grammar, and in the
/// same breath asked it to preserve the speaker's wording and sentence order.
/// Those two instructions pull against each other. Strict lifts the wording
/// constraint, and only that one: meaning, facts, and the order of the
/// speaker's ideas stay protected, because the failure mode on this side of
/// the dial is the model writing sentences nobody said.
///
/// Measured against gemma3:4b (the default local model at the time), six
/// ungrammatical
/// dictations, the two strengths agreed on half of them. Light is already
/// competent at subject and verb agreement, articles, and double negatives,
/// so the dial is not the difference between broken and fixed. Where strict
/// actually earns its place is tense and aspect and word order: "i am working
/// in this company since three years" stays wrong under light ("I am working
/// in this company for three years") and comes out right under strict ("I
/// have been working at this company for three years"). That is exactly the
/// error a non-native speaker makes and cannot hear, which is who this
/// setting is for. Do not oversell it as a rewrite mode; it is a tighter
/// grammar pass with the wording handcuff removed.
enum Grammar: String, CaseIterable {
    /// Fix what can be fixed without moving the speaker's words around.
    case light
    /// Rewrite ungrammatical sentences into correct ones.
    case strict

    /// Style wins; an empty style value inherits the global setting. Mirrors
    /// `Translation.resolve` so per-style overrides all behave the same way.
    static func resolve(style: Style?, fallback: String) -> Grammar {
        let chosen = (style?.grammar.isEmpty == false) ? style!.grammar : fallback
        return Grammar(rawValue: chosen) ?? .light
    }

    /// The prompt rules that differ between the two strengths. Everything
    /// else in the cleanup prompt is shared.
    var rules: String {
        switch self {
        case .light:
            return """
            - Preserve the speaker's wording, meaning, tone, and sentence order
            - Do NOT summarize, restructure, add, or omit content
            """
        case .strict:
            return """
            - Fix ungrammatical sentences properly: subject and verb agreement, \
            verb tense, plurals, articles, prepositions, and word order. \
            Rephrase or reorder a sentence when that is what correctness needs.
            - Preserve the speaker's meaning, tone, register, and the order of \
            their ideas
            - Do NOT summarize, add, or omit content, and never invent a fact, \
            name, or number that was not spoken
            - Repair a word only when the intended word is obvious from \
            context. If a word looks misheard but you cannot tell what was \
            meant, leave it exactly as it is rather than guessing
            """
        }
    }

    /// Whether a cleaned result is close enough in size to be believable.
    ///
    /// Cleanup only ever shortens or lightly edits, so much shorter means a
    /// summary or a refusal and much longer means leaked reasoning or
    /// commentary. Either way the raw words are safer. Strict gets a wider
    /// ceiling because correcting grammar genuinely adds characters: articles,
    /// auxiliaries, and inflections the speaker dropped are exactly what it is
    /// there to put back.
    func plausible(original: String, cleaned: String) -> Bool {
        guard !cleaned.isEmpty else { return false }
        let n = Double(original.count)
        let ceiling = self == .strict ? 1.8 * n + 60 : 1.5 * n + 40
        return Double(cleaned.count) >= 0.3 * n && Double(cleaned.count) <= ceiling
    }

    var label: String {
        switch self {
        case .light: return "Light"
        case .strict: return "Strict"
        }
    }
}
