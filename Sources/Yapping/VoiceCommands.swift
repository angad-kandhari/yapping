import Foundation

/// Spoken formatting commands: "new paragraph", "comma", "scratch that".
///
/// Nine commands, and the list stays short on purpose. Every literal added
/// is a word the user can no longer dictate as a word, and when that bites
/// it bites silently.
///
/// Design note, learned the hard way: an earlier version replaced commands
/// with sentinel tokens and asked the cleanup model to copy them through.
/// Measured against the default local model (gemma3:4b), zero of five
/// markers survived, which would have made cleanup and voice commands
/// mutually exclusive. So the model never sees a marker now:
/// - punctuation is inserted as real characters before cleanup, which the
///   model is happy to preserve because preserving wording is its job
/// - line breaks split the text into segments that are cleaned separately
///   and rejoined afterwards, so a paragraph break cannot be "corrected"
///   out of existence by anything
enum VoiceCommands {
    /// Text split at line breaks, with the breaks held safely outside the
    /// reach of any model.
    struct Prepared: Equatable {
        /// Pieces to clean, in order.
        var segments: [String]
        /// What rejoins them; always `segments.count - 1` long.
        var separators: [String]

        var isPlain: Bool { separators.isEmpty }
    }

    /// Phrases that insert a character inline. Longest first so
    /// "exclamation point" is not shadowed by a shorter match.
    private static let punctuation: [(phrase: String, insert: String)] = [
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("question mark", "?"),
        ("full stop", "."),
        ("period", "."),
        ("comma", ","),
    ]

    /// Phrases that break the text. Longest first.
    private static let breaks: [(phrase: String, separator: String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
    ]

    // MARK: - Preparing

    static func prepare(_ text: String, enabled: Bool = true) -> Prepared {
        guard enabled else { return Prepared(segments: [text], separators: []) }

        // Transforms first: these are edits, not insertions
        var working = applyCaps(scratch(text))

        // Punctuation becomes real characters. The cleanup model preserves
        // wording, so a comma it can see is a comma it keeps.
        for (phrase, insert) in punctuation {
            working = replacingSpokenPhrase(in: working, phrase: phrase, with: insert)
        }

        // Line breaks become split points, using a placeholder that exists
        // only inside this function and never reaches a model.
        var separators: [String] = []
        let mark = "\u{0001}"
        for (phrase, separator) in breaks {
            working = replacingSpokenPhrase(
                in: working, phrase: phrase, with: mark + separator + mark)
        }

        guard working.contains(mark) else {
            return Prepared(segments: [tidy(working)], separators: [])
        }

        var segments: [String] = []
        var current = ""
        var index = working.startIndex
        while index < working.endIndex {
            if working[index] == "\u{0001}" {
                // The separator sits between two marks
                let after = working.index(after: index)
                guard let close = working[after...].firstIndex(of: "\u{0001}") else { break }
                segments.append(tidy(current))
                separators.append(String(working[after..<close]))
                current = ""
                index = working.index(after: close)
            } else {
                current.append(working[index])
                index = working.index(after: index)
            }
        }
        segments.append(tidy(current))
        return Prepared(segments: segments, separators: separators)
    }

    /// Put the cleaned pieces back together around the breaks.
    static func rejoin(_ cleaned: [String], _ prepared: Prepared) -> String {
        guard cleaned.count == prepared.segments.count else {
            // Mismatched counts should be impossible; fall back to the
            // prepared text rather than dropping anyone's words.
            return joined(prepared.segments, prepared.separators)
        }
        return joined(cleaned, prepared.separators)
    }

    private static func joined(_ pieces: [String], _ separators: [String]) -> String {
        var out = pieces.first ?? ""
        for (index, separator) in separators.enumerated() where index + 1 < pieces.count {
            out += separator + pieces[index + 1]
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Transforms

    /// "scratch that" and "delete that" drop the clause before them.
    static func scratch(_ text: String) -> String {
        let pattern = "(?i)(?<=^|[\\s.,!?])(scratch|delete) that(?=$|[\\s.,!?])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        while let match = regex.firstMatch(
            in: out, range: NSRange(out.startIndex..., in: out)),
            let phrase = Range(match.range, in: out) {
            let before = out[out.startIndex..<phrase.lowerBound]
            let cutFrom = before.lastIndex(where: { ".,!?\n".contains($0) })
                .map { before.index(after: $0) } ?? out.startIndex
            out.replaceSubrange(cutFrom..<phrase.upperBound, with: "")
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return collapseSpaces(out)
    }

    /// "caps on" ... "caps off" title-cases the words between.
    static func applyCaps(_ text: String) -> String {
        let onPattern = "(?i)(?<=^|[\\s.,!?])caps on(?=$|[\\s.,!?])"
        let offPattern = "(?i)(?<=^|[\\s.,!?])caps off(?=$|[\\s.,!?])"
        guard let onRegex = try? NSRegularExpression(pattern: onPattern),
              let offRegex = try? NSRegularExpression(pattern: offPattern) else { return text }

        var out = text
        while let on = onRegex.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let onRange = Range(on.range, in: out) {
            let afterOn = onRange.upperBound
            let tailRange = NSRange(afterOn..<out.endIndex, in: out)
            let off = offRegex.firstMatch(in: out, range: tailRange)
            let offRange = off.flatMap { Range($0.range, in: out) }
            let capsEnd = offRange?.lowerBound ?? out.endIndex

            let segment = String(out[afterOn..<capsEnd])
            let capitalized = segment
                .split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")

            let replaceEnd = offRange?.upperBound ?? out.endIndex
            out.replaceSubrange(onRange.lowerBound..<replaceEnd, with: capitalized)
        }
        return collapseSpaces(out)
    }

    // MARK: - Helpers

    /// Replace a spoken phrase wherever it stands alone as words. Bounded on
    /// whitespace or punctuation rather than \b, because the recognizer may
    /// have already attached a comma to the phrase.
    private static func replacingSpokenPhrase(
        in text: String, phrase: String, with replacement: String
    ) -> String {
        let pattern = "(?i)(?<=^|[\\s.,!?])\(NSRegularExpression.escapedPattern(for: phrase))(?=$|[\\s.,!?])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// No space before punctuation, one after. Cheap to get wrong and very
    /// visible when it is.
    static func tidy(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(
            of: #"[ \t]+([,.!?])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"([,.!?])(?=[^\s\d])"#, with: "$1 ", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
