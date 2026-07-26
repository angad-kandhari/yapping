import SwiftUI
import Speech

struct SettingsView: View {
    @State private var tab = 0

    var body: some View {
        BrandChrome(title: "settings") {
            BrandTabs(tabs: ["General", "Dictionary", "Styles", "About"], selection: $tab)
            Group {
                switch tab {
                case 0: GeneralSettings()
                case 1: DictionarySettings()
                case 2: StylesSettings()
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
            }
            Section("Cleanup") {
                Toggle("Clean up transcripts with a local model", isOn: $config.cleanupEnabled)
                TextField("Ollama model", text: $config.ollamaModel)
                TextField("Ollama host", text: $config.ollamaHost)
                Text("If Ollama is unreachable, the raw transcript is used. Words are never lost.")
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
            }
        }
        .formStyle(.grouped)
        .task {
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
                        config.styles.removeAll { $0.id == style.id }
                    } label: { Text("Delete style") }
                }
            }
            Button("Add style") {
                config.styles.append(Style(name: "New style", appPatterns: [], prompt: ""))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            BrandLogo(height: 22)
            Text("yapping").font(.system(size: 28, weight: .bold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Hold the globe key. Yap. Done.\nEverything stays on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/angad-kandhari/yapping",
                 destination: URL(string: "https://github.com/angad-kandhari/yapping")!)
                .foregroundStyle(Brand.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
