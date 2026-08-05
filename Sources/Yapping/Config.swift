import Foundation
import Combine

struct Replacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var spoken: String = ""
    var written: String = ""
}

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String = ""
    var expansion: String = ""
}

/// App-wide settings, persisted to UserDefaults. Observed by SwiftUI views;
/// read directly (thread-safe enough for our purposes) by the pipeline.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var localeID: String { didSet { d.set(localeID, forKey: "localeID") } }
    @Published var cleanupEnabled: Bool { didSet { d.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    /// "apple" (on-device Foundation Models, zero setup), "ollama", "custom"
    @Published var cleanupProvider: String { didSet { d.set(cleanupProvider, forKey: "cleanupProvider") } }
    @Published var customBaseURL: String { didSet { d.set(customBaseURL, forKey: "customBaseURL") } }
    @Published var customModel: String { didSet { d.set(customModel, forKey: "customModel") } }
    @Published var customKey: String { didSet { d.set(customKey, forKey: "customKey") } }
    @Published var ollamaModel: String { didSet { d.set(ollamaModel, forKey: "ollamaModel") } }
    @Published var ollamaHost: String { didSet { d.set(ollamaHost, forKey: "ollamaHost") } }
    @Published var soundsEnabled: Bool { didSet { d.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var copyInsteadOfPaste: Bool { didSet { d.set(copyInsteadOfPaste, forKey: "copyInsteadOfPaste") } }
    @Published var trailingSpace: Bool { didSet { d.set(trailingSpace, forKey: "trailingSpace") } }
    @Published var handsFreeAutoStop: Bool { didSet { d.set(handsFreeAutoStop, forKey: "handsFreeAutoStop") } }
    @Published var sendCommand: Bool { didSet { d.set(sendCommand, forKey: "sendCommand") } }
    @Published var dictionary: [String] { didSet { saveJSON(dictionary, key: "dictionary") } }
    @Published var replacements: [Replacement] { didSet { saveJSON(replacements, key: "replacements") } }
    @Published var snippets: [Snippet] { didSet { saveJSON(snippets, key: "snippets") } }
    @Published var styles: [Style] { didSet { saveJSON(styles, key: "styles") } }
    @Published var useFieldContext: Bool { didSet { d.set(useFieldContext, forKey: "useFieldContext") } }
    @Published var hudEnabled: Bool { didSet { d.set(hudEnabled, forKey: "hudEnabled") } }
    /// Input device UID to pin capture to; empty means system default.
    @Published var micDeviceUID: String { didSet { d.set(micDeviceUID, forKey: "micDeviceUID") } }
    /// Live words above the Dock while dictating.
    @Published var livePreview: Bool { didSet { d.set(livePreview, forKey: "livePreview") } }

    private let d = UserDefaults.standard

    private init() {
        localeID = d.string(forKey: "localeID") ?? "en_US"
        cleanupEnabled = d.object(forKey: "cleanupEnabled") as? Bool ?? true
        cleanupProvider = d.string(forKey: "cleanupProvider") ?? "apple"
        customBaseURL = d.string(forKey: "customBaseURL") ?? ""
        customModel = d.string(forKey: "customModel") ?? ""
        customKey = d.string(forKey: "customKey") ?? ""
        ollamaModel = d.string(forKey: "ollamaModel") ?? "gemma3:4b"
        ollamaHost = d.string(forKey: "ollamaHost") ?? "http://localhost:11434"
        soundsEnabled = d.object(forKey: "soundsEnabled") as? Bool ?? true
        copyInsteadOfPaste = d.object(forKey: "copyInsteadOfPaste") as? Bool ?? false
        trailingSpace = d.object(forKey: "trailingSpace") as? Bool ?? true
        handsFreeAutoStop = d.object(forKey: "handsFreeAutoStop") as? Bool ?? false
        sendCommand = d.object(forKey: "sendCommand") as? Bool ?? true
        dictionary = Self.loadJSON([String].self, key: "dictionary") ?? []
        replacements = Self.loadJSON([Replacement].self, key: "replacements") ?? []
        snippets = Self.loadJSON([Snippet].self, key: "snippets") ?? []
        var loadedStyles = Self.loadJSON([Style].self, key: "styles") ?? Style.defaults

        // Style seeding is versioned rather than one boolean per preset,
        // which does not scale past the first one. Version 1 seeded Prompt.
        let seeded = d.integer(forKey: "stylesSchemaVersion")
        if seeded < 1 {
            // Carry over the old single-purpose flag before retiring it
            let hadPrompt = d.bool(forKey: "promptStyleSeeded")
            if !hadPrompt, !loadedStyles.contains(where: { $0.name == "Prompt" }) {
                loadedStyles.append(Style.promptPreset)
            }
            d.set(1, forKey: "stylesSchemaVersion")
        }
        styles = loadedStyles
        useFieldContext = d.object(forKey: "useFieldContext") as? Bool ?? true
        hudEnabled = d.object(forKey: "hudEnabled") as? Bool ?? false
        micDeviceUID = d.string(forKey: "micDeviceUID") ?? ""
        livePreview = d.object(forKey: "livePreview") as? Bool ?? true
    }

    private func saveJSON<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            d.set(data, forKey: key)
        }
    }

    /// Routed through Store so an unreadable blob leaves a rescue copy and a
    /// log line. Losing hand-written style prompts silently was the worst
    /// version of this bug.
    private static func loadJSON<T: Decodable>(_ type: T.Type, key: String) -> T? {
        Store.loadDefaults(type, key: key, label: key)
    }

    /// Replacement pairs and snippets applied to final text, case-insensitive.
    func applyTextRules(to text: String) -> String {
        var result = text
        for rule in replacements where !rule.spoken.isEmpty {
            result = result.replacingOccurrences(
                of: rule.spoken, with: rule.written, options: [.caseInsensitive])
        }
        for snippet in snippets where !snippet.trigger.isEmpty {
            result = result.replacingOccurrences(
                of: snippet.trigger, with: snippet.expansion, options: [.caseInsensitive])
        }
        return result
    }

    // MARK: - Login item (managed LaunchAgent)

    private var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.angad.dictate.plist")
    }

    var launchAtLogin: Bool {
        FileManager.default.fileExists(atPath: agentPlist.path)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.angad.dictate</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/Applications/Yapping.app/Contents/MacOS/yapping</string>
                </array>
                <key>RunAtLoad</key><true/>
                <key>ProcessType</key><string>Interactive</string>
            </dict>
            </plist>
            """
            try? plist.write(to: agentPlist, atomically: true, encoding: .utf8)
        } else {
            let unload = Process()
            unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            unload.arguments = ["unload", agentPlist.path]
            try? unload.run()
            unload.waitUntilExit()
            try? FileManager.default.removeItem(at: agentPlist)
        }
        objectWillChange.send()
    }
}
