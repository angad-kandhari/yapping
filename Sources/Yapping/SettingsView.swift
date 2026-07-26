import SwiftUI
import Speech

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            DictionarySettings()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
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

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("yapping").font(.system(size: 28, weight: .bold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Hold the globe key. Yap. Done.\nEverything stays on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/angad729/yapping",
                 destination: URL(string: "https://github.com/angad729/yapping")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
