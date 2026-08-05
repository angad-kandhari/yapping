import Foundation

/// Which language a dictation should come out in, and whether a translation
/// came back looking like one.
enum Translation {
    /// Style wins; an empty style value inherits the global default.
    static func resolve(style: Style?, fallback: String) -> String? {
        let chosen = (style?.targetLanguage.isEmpty == false)
            ? style!.targetLanguage
            : fallback
        return chosen.isEmpty ? nil : chosen
    }

    /// Deliberately much wider than the cleanup guard. Character counts vary
    /// enormously across scripts: English into Japanese contracts by two or
    /// three times, English into German expands by about a third. Cleanup's
    /// 0.3x to 1.5x window would reject correct translations all day.
    static func looksSane(source: String, output: String) -> Bool {
        guard !output.isEmpty else { return false }
        let n = Double(source.count)
        return Double(output.count) >= 0.25 * n && Double(output.count) <= 3 * n + 80
    }

    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
    }

    /// A curated output list. Not SpeechTranscriber.supportedLocales: that is
    /// what the recognizer can hear, and this is what the model can write.
    static let targets: [String] = [
        "en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "no", "fi",
        "pl", "tr", "ru", "uk", "ar", "he", "hi", "bn", "ta", "ur",
        "zh-Hans", "zh-Hant", "ja", "ko", "th", "vi", "id", "ms",
    ]
}
