import SwiftUI
import Speech

struct SettingsPane: View {
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "settings", sub: "everything one click deep, nothing buried")
                .padding(.horizontal, 36)
                .padding(.top, 48)
            GeneralSettings()
                .scrollContentBackground(.hidden)
        }
    }
}

struct DictionaryPane: View {
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "dictionary", sub: "names and jargon the recognizer should trust")
                .padding(.horizontal, 36)
                .padding(.top, 48)
            DictionarySettings()
                .scrollContentBackground(.hidden)
        }
    }
}

struct StylesPane: View {
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "styles", sub: "the active style is chosen from the frontmost app when you start talking")
                .padding(.horizontal, 36)
                .padding(.top, 48)
            StylesSettings()
                .scrollContentBackground(.hidden)
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var config = ConfigStore.shared
    @State private var locales: [Locale] = []
    @State private var mics: [AudioInputDevice] = []
    @State private var launchAtLogin = ConfigStore.shared.launchAtLogin
    @State private var providerStatus: (label: String, good: Bool)?

    var body: some View {
        Form {
            Section("Speech") {
                Picker("Language", selection: $config.localeID) {
                    ForEach(locales, id: \.identifier) { locale in
                        Text(locale.localizedString(forIdentifier: locale.identifier)
                             ?? locale.identifier)
                            .tag(locale.identifier(.bcp47))
                    }
                }
                .help("Changing language downloads that on-device speech model once.")
                Picker("Microphone", selection: $config.micDeviceUID) {
                    Text("System default").tag("")
                    ForEach(mics) { mic in
                        Text(mic.name).tag(mic.uid)
                    }
                }
                Text("Pinning the built-in mic keeps dictation sharp even when AirPods connect; their mic records at lower quality. An unplugged pinned mic quietly falls back to the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cleanup") {
                Toggle("Clean up transcripts with a local model", isOn: $config.cleanupEnabled)
                Group {
                    Picker("Provider", selection: $config.cleanupProvider) {
                        Text("Apple Intelligence (built in)").tag("apple")
                        Text("Ollama").tag("ollama")
                        Text("Custom endpoint").tag("custom")
                    }
                    switch config.cleanupProvider {
                    case "ollama":
                        TextField("Ollama model", text: $config.ollamaModel)
                        TextField("Ollama host", text: $config.ollamaHost)
                    case "custom":
                        TextField("Base URL (OpenAI compatible, e.g. http://localhost:1234/v1)",
                                  text: $config.customBaseURL)
                        TextField("Model (optional)", text: $config.customModel)
                        SecureField("API key (optional, stored locally)", text: $config.customKey)
                    default:
                        Text("Apple's on-device model. Nothing to install; falls back to Ollama if Apple Intelligence is off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let providerStatus {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(providerStatus.good ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(providerStatus.label)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!config.cleanupEnabled)
                Text("If the provider fails or over-edits, the raw transcript is used. Words are never lost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spoken commands") {
                Toggle("Honor spoken formatting commands", isOn: $config.voiceCommands)
                Text("Say \"new line\", \"new paragraph\", \"comma\", \"period\", \"question mark\", or \"exclamation mark\" and you get the character instead of the word. \"Scratch that\" drops what you just said; \"caps on\" and \"caps off\" title-case a stretch of words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                Toggle("Copy to clipboard instead of pasting", isOn: $config.copyInsteadOfPaste)
                Toggle("Trailing space after each dictation", isOn: $config.trailingSpace)
                Toggle("\"Send it\" presses Return", isOn: $config.sendCommand)
                Text("End a dictation with \"send it\" and the message goes out with zero keypresses. Skipped in verbatim styles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hands-free") {
                Toggle("Silence ends hands-free dictation", isOn: $config.handsFreeAutoStop)
                Text("Double-tap \u{1F310} to talk without holding; tap again or press Esc to finish. With this on, about 2.5 seconds of quiet also finishes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Sounds", isOn: $config.soundsEnabled)
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        config.setLaunchAtLogin(newValue)
                    }
                Toggle("Use on-screen context", isOn: $config.useFieldContext)
                Text("Reads the focused text field so cleanup matches its tone. Processed locally, never leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Waveform above the Dock", isOn: $config.hudEnabled)
                Text("The yapping logo dances with your voice while you talk.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show words as you speak", isOn: $config.livePreview)
                Text("Your words appear live above the Dock while you dictate, so you can see the recognizer keeping up.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Never dictate into password fields", isOn: $config.blockSecureFields)
                Text("When a field reports itself as a password field, the mic does not start and nothing is saved. Apps that do not report it, including browsers, Electron apps, and terminal password prompts, cannot be detected, so treat this as a safety net rather than a guarantee.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: "\(config.cleanupProvider)|\(config.ollamaHost)|\(config.cleanupEnabled)") {
            await refreshProviderStatus()
        }
        .task {
            mics = AudioDevices.inputs()
            // A pinned mic that is gone right now still needs a menu entry,
            // or the picker would silently snap to System default
            if !config.micDeviceUID.isEmpty,
               !mics.contains(where: { $0.uid == config.micDeviceUID }) {
                mics.append(AudioInputDevice(
                    uid: config.micDeviceUID, name: "Remembered mic (not connected)"))
            }
            let supported = await SpeechTranscriber.supportedLocales
            locales = supported.sorted {
                $0.identifier < $1.identifier
            }
            if locales.isEmpty {
                locales = [Locale(identifier: "en_US")]
            }
        }
    }

    private func refreshProviderStatus() async {
        guard config.cleanupEnabled else { providerStatus = nil; return }
        switch config.cleanupProvider {
        case "apple":
            let available = Cleanup.appleAvailable
            providerStatus = (available
                ? "Apple Intelligence is available"
                : "Apple Intelligence is off; cleanup will try Ollama", available)
        case "ollama":
            let up = await Cleanup.reachable()
            providerStatus = (up
                ? "Ollama is reachable at \(config.ollamaHost)"
                : "Ollama is not responding at \(config.ollamaHost)", up)
        default:
            providerStatus = ("Custom endpoints are checked at first use.", true)
        }
    }
}

private struct DictionarySettings: View {
    @ObservedObject var config = ConfigStore.shared
    @State private var newWord = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add a name, term, or acronym", text: $newWord)
                        .onSubmit(addWord)
                    Button("Add", action: addWord).disabled(newWord.isEmpty)
                }
                ForEach(config.dictionary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(role: .destructive) {
                            config.dictionary.removeAll { $0 == word }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Personal dictionary")
            } footer: {
                Text("These words bias speech recognition and are preserved by cleanup. Great for names: it's Angad, not \"on God\".")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Replacements (heard, then written)") {
                rulesEditor(rules: $config.replacements)
            }
            Section("Snippets (say the trigger, get the expansion)") {
                snippetsEditor(snippets: $config.snippets)
            }
        }
        .formStyle(.grouped)
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !config.dictionary.contains(word) else { return }
        config.dictionary.append(word)
        newWord = ""
    }

    private func rulesEditor(rules: Binding<[Replacement]>) -> some View {
        VStack(alignment: .leading) {
            ForEach(rules) { $rule in
                HStack {
                    TextField("heard", text: $rule.spoken)
                    Image(systemName: "arrow.right")
                    TextField("written", text: $rule.written)
                    Button(role: .destructive) {
                        rules.wrappedValue.removeAll { $0.id == rule.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                }
            }
            Button("Add replacement") { rules.wrappedValue.append(Replacement()) }
        }
    }

    private func snippetsEditor(snippets: Binding<[Snippet]>) -> some View {
        VStack(alignment: .leading) {
            ForEach(snippets) { $snippet in
                HStack {
                    TextField("trigger phrase", text: $snippet.trigger)
                    Image(systemName: "arrow.right")
                    TextField("expansion", text: $snippet.expansion)
                    Button(role: .destructive) {
                        snippets.wrappedValue.removeAll { $0.id == snippet.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                }
            }
            Button("Add snippet") { snippets.wrappedValue.append(Snippet()) }
        }
    }
}

private struct StylesSettings: View {
    @ObservedObject var config = ConfigStore.shared
    @State private var styleToDelete: Style?

    var body: some View {
        Form {
            ForEach($config.styles) { $style in
                Section(style.name.isEmpty ? "Style" : style.name) {
                    TextField("Name", text: $style.name)
                    TextField("Applies when bundle id contains (comma separated)",
                              text: Binding(
                                get: { style.appPatterns.joined(separator: ", ") },
                                set: { style.appPatterns = $0.split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) } }))
                    Toggle("Verbatim (skip cleanup entirely)", isOn: $style.verbatim)
                    if !style.verbatim {
                        TextEditor(text: $style.prompt)
                            .font(.system(.body))
                            .frame(minHeight: 56)
                    }
                    StyleTester(style: style)
                    Button(role: .destructive) {
                        styleToDelete = style
                    } label: { Text("Delete style") }
                }
            }
            Button("Add style") {
                config.styles.append(Style(name: "New style", appPatterns: [], prompt: ""))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete the \"\(styleToDelete?.name ?? "")\" style? Its prompt is gone for good.",
            isPresented: Binding(
                get: { styleToDelete != nil },
                set: { if !$0 { styleToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Style", role: .destructive) {
                if let style = styleToDelete {
                    config.styles.removeAll { $0.id == style.id }
                }
                styleToDelete = nil
            }
        }
    }
}


/// Author a prompt without having to dictate at it. Runs the real pipeline,
/// because a tester that approximates the pipeline teaches the wrong lesson.
private struct StyleTester: View {
    let style: Style
    @ObservedObject private var config = ConfigStore.shared
    @AppStorage("styleTestSample") private var sample =
        "um so i was thinking we could maybe ship the thing on friday you know"
    @State private var result: String?
    @State private var elapsed: Int?
    @State private var running = false
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Test this style", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Say something the way you would dictate it", text: $sample, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button(running ? "Running..." : "Test") { run() }
                        .disabled(running || sample.isEmpty)
                    if let elapsed {
                        Text("\(elapsed) ms \u{00B7} \(providerName)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }

                if style.verbatim {
                    Text("Verbatim style: text is pasted exactly as heard, so cleanup never runs. Spoken commands still apply.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !config.cleanupEnabled {
                    Text("Cleanup is turned off in Settings, so the raw transcript is what gets pasted.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let result {
                    VStack(alignment: .leading, spacing: 4) {
                        MonoLabel("Result")
                        Text(result)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                }
            }
            .padding(.top, 6)
        }
    }

    private var providerName: String {
        switch config.cleanupProvider {
        case "apple": return "Apple Intelligence"
        case "custom": return config.customModel.isEmpty ? "custom endpoint" : config.customModel
        default: return config.ollamaModel
        }
    }

    private func run() {
        running = true
        result = nil
        let text = sample
        let chosen = style
        Task {
            let started = Date()
            // Exactly what a real dictation does, in the same order
            let prepared = VoiceCommands.prepare(
                text, enabled: config.voiceCommands && chosen.voiceCommands)
            var pieces: [String] = []
            for segment in prepared.segments {
                if chosen.verbatim {
                    pieces.append(segment)
                } else {
                    pieces.append(await Cleanup.polish(text: segment, style: chosen))
                }
            }
            let joined = VoiceCommands.rejoin(pieces, prepared)
            let final = config.applyTextRules(to: joined)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            await MainActor.run {
                result = final
                elapsed = ms
                running = false
            }
        }
    }
}
