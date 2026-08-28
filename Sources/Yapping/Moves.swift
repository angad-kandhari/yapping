import SwiftUI

/// The in-app reference for everything you can say or do. The onboarding
/// tour shows once; this pane is the place a user can come back to. It is
/// the only complete list of the spoken command vocabulary in the UI, so
/// if a command is added or cut, this file changes in the same commit.
struct MovesPane: View {
    @ObservedObject private var config = ConfigStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(title: "moves",
                           sub: "everything you can say or do, on one page")

                gesturesCard
                commandsCard
                moreCard
            }
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
    }

    private var gesturesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Gestures")
            row("Hold and talk",
                "Hold the globe (fn) key, speak, release. The words land at your cursor.")
            row("Double-tap for hands-free",
                "Tap globe twice to talk without holding. Tap again, press Esc, or go quiet to finish.")
            row("Edit by voice",
                "Select any text first, then hold globe and speak an instruction. The selection is rewritten.")
            row("Esc while holding",
                "Discards the dictation on purpose. Nothing is kept.")
            row("Any other key while holding",
                "Cancels the paste, but the words are saved to History in case it was a slip.")
            row("Say \"send it\" at the end",
                "The phrase is stripped and Return is pressed for you."
                + (config.sendCommand ? "" : " Currently off in Settings, Output."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCard()
    }

    private var commandsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoLabel("Spoken commands")
                Spacer()
                if !config.voiceCommands {
                    Text("Off in Settings, Spoken commands")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            command("\"period\" or \"full stop\"", ".")
            command("\"comma\"", ",")
            command("\"question mark\"", "?")
            command("\"exclamation point\" or \"exclamation mark\"", "!")
            command("\"new line\"", "a line break")
            command("\"new paragraph\"", "a paragraph break")
            command("\"scratch that\" or \"delete that\"", "deletes the clause before it")
            command("\"caps on\" ... \"caps off\"", "Title Case for the words between")
            Text("Nine commands, on purpose: every phrase on this list is one you can no longer dictate as words.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCard()
    }

    private var moreCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Also good to know")
            row("Speak one language, paste another",
                "Turn on Language out in Settings, globally or per style. Translation runs on the same local provider.")
            row("Transcribe a file",
                "Drop any audio or video on the menu bar icon, or pick Transcribe File from the menu.")
            row("Listen to what your Mac is playing",
                "Listen to System Audio in the menu transcribes lectures, podcasts, and the other side of calls.")
            row("Styles follow the app",
                "Chat stays casual, email stays sharp, terminals stay verbatim. Tune them in the Styles pane.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCard()
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func command(_ phrase: String, _ result: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(phrase)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 300, alignment: .leading)
            Text(result).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
