import SwiftUI
import Speech

struct SettingsView: View {
    @State private var tab = 0

    var body: some View {
        BrandChrome(title: "settings") {
            BrandTabs(tabs: ["General", "Cleanup", "Dictionary", "Styles", "About"],
                      selection: $tab)
            Group {
                switch tab {
                case 0: GeneralSettings()
                case 1: CleanupSettings()
                case 2: DictionarySettings()
                case 3: StylesSettings()
                default: AboutSettings()
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 560, height: 500)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var config = ConfigStore.shared
    @State private var locales: [Locale] = []
    @State private var mics: [AudioInputDevice] = []
    @State private var launchAtLogin = ConfigStore.shared.launchAtLogin

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
            }
        }
        .formStyle(.grouped)
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
}

private struct CleanupSettings: View {
    @ObservedObject var config = ConfigStore.shared
    @State private var status: (label: String, good: Bool)?

    var body: some View {
        Form {
            Section {
                Toggle("Clean up transcripts with a local model", isOn: $config.cleanupEnabled)
                Text("If the provider fails or over-edits, the raw transcript is used. Words are never lost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider") {
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
                if let status {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.good ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(status.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!config.cleanupEnabled)
        }
        .formStyle(.grouped)
        .task(id: "\(config.cleanupProvider)|\(config.ollamaHost)|\(config.cleanupEnabled)") {
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        guard config.cleanupEnabled else { status = nil; return }
        switch config.cleanupProvider {
        case "apple":
            let available = Cleanup.appleAvailable
            status = (available
                ? "Apple Intelligence is available"
                : "Apple Intelligence is off; cleanup will try Ollama", available)
        case "ollama":
            let up = await Cleanup.reachable()
            status = (up
                ? "Ollama is reachable at \(config.ollamaHost)"
                : "Ollama is not responding at \(config.ollamaHost)", up)
        default:
            status = ("Custom endpoints are checked at first use.", true)
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
            Section {
                Text("The active style is chosen from the frontmost app when you start talking. Every prompt is editable; nothing about the rewriting is hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

private struct AboutSettings: View {
    @ObservedObject var config = ConfigStore.shared
    @ObservedObject var netLog = NetLog.shared

    private var providerLine: String {
        switch config.cleanupProvider {
        case "apple":
            return "Apple Intelligence, on this Mac (no network at all)"
        case "custom":
            return config.customBaseURL.isEmpty
                ? "your custom endpoint (not configured yet)"
                : config.customBaseURL
        default:
            return "\(config.ollamaHost) (your Ollama)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("yapping").font(.system(size: 24, weight: .bold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .foregroundStyle(.secondary)
                Text("Hold the globe key. Yap. Done.")
                    .foregroundStyle(.secondary)
                Link("github.com/angad-kandhari/yapping",
                     destination: URL(string: "https://github.com/angad-kandhari/yapping")!)
                    .foregroundStyle(Brand.accent)

                privacyCard
                    .padding(.top, 6)

                VStack(spacing: 4) {
                    Button("Reveal Log File") { Log.reveal() }
                    Text("Attach it when reporting a bug.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRIVACY")
                .font(.caption.bold())
                .foregroundStyle(Brand.accent)
            Text("This app can reach exactly three things, and nothing else:")
                .font(.callout)
            bullet("Your cleanup provider: \(providerLine)")
            bullet("api.github.com, once a day, to check for updates")
            bullet("github.com, only when you click Update Now")
            Text("Your voice and transcripts never leave this Mac. History and stats are saved with owner-only file permissions.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("Connections this session")
                .font(.caption.bold())
            if netLog.events.isEmpty {
                Text("None yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(netLog.events.prefix(8))) { event in
                    HStack(spacing: 6) {
                        Text(event.date, style: .time)
                        Text(event.host).fontWeight(.medium)
                        Text(event.purpose)
                        if !event.ok {
                            Text("failed").foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}").foregroundStyle(Brand.accent)
            Text(text)
        }
        .font(.callout)
    }
}
