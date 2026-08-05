import Foundation

/// Word-level diff between what was heard and what was pasted.
///
/// History already stores both strings, so this costs nothing to keep and it
/// is the honest version of the transparency promise: not just "here is the
/// raw text somewhere below", but exactly which words cleanup changed.
enum TextDiff {
    enum Kind { case same, removed, added }

    struct Span: Equatable {
        let kind: Kind
        let text: String
    }

    /// Past this many words the table costs more than the feature is worth,
    /// so a very long dictation simply does not offer a diff. Nil means "too
    /// long to show", which the caller reports rather than hides.
    static let limit = 250

    /// Spans in reading order, adjacent spans of the same kind merged.
    /// Comparison is case sensitive on purpose: a capitalization fix is a
    /// correction, and hiding it would undersell what cleanup did.
    static func words(from before: String, to after: String) -> [Span]? {
        let a = tokens(before)
        let b = tokens(after)
        guard a.count <= limit, b.count <= limit else { return nil }
        guard !a.isEmpty || !b.isEmpty else { return [] }

        // Longest common subsequence, filled from the back so the walk below
        // can read it forwards and keep the spans in reading order.
        var lcs = [[Int]](
            repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var spans: [Span] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                append(&spans, .same, a[i])
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                append(&spans, .removed, a[i])
                i += 1
            } else {
                append(&spans, .added, b[j])
                j += 1
            }
        }
        while i < a.count {
            append(&spans, .removed, a[i])
            i += 1
        }
        while j < b.count {
            append(&spans, .added, b[j])
            j += 1
        }
        return spans
    }

    /// How many separate edits the spans represent. A stretch of removed
    /// words followed immediately by added ones is one correction, not two,
    /// because that is a single substitution as the reader sees it.
    static func corrections(_ spans: [Span]) -> Int {
        var count = 0
        var inEdit = false
        for span in spans {
            if span.kind == .same {
                inEdit = false
            } else if !inEdit {
                count += 1
                inEdit = true
            }
        }
        return count
    }

    // MARK: - Helpers

    /// Split on whitespace, punctuation left attached. "store" against
    /// "store." should read as a change, because it is one.
    private static func tokens(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
    }

    private static func append(_ spans: inout [Span], _ kind: Kind, _ word: Substring) {
        if let last = spans.last, last.kind == kind {
            spans[spans.count - 1] = Span(kind: kind, text: last.text + " " + word)
        } else {
            spans.append(Span(kind: kind, text: String(word)))
        }
    }
}
