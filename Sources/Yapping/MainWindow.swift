import AppKit
import SwiftUI

/// The sections behind the rail, in rail order.
enum MainSection: String, CaseIterable, Identifiable {
    case dictations, stats, transcripts, styles, dictionary, settings, diagnostics, privacy, moves
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dictations: return "Dictations"
        case .stats: return "Stats"
        case .transcripts: return "Transcripts"
        case .styles: return "Styles"
        case .dictionary: return "Dictionary"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        case .privacy: return "Privacy"
        case .moves: return "Moves"
        }
    }

    var icon: String {
        switch self {
        case .dictations: return "clock"
        case .stats: return "chart.bar"
        case .transcripts: return "doc.text"
        case .styles: return "paintbrush"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        case .privacy: return "checkmark.shield"
        case .moves: return "questionmark.circle"
        }
    }
}

/// Externally settable so menu items can deep-link into a section.
final class MainWindowState: ObservableObject {
    static let shared = MainWindowState()
    @Published var section: MainSection = .dictations
    /// Set by AppDelegate; lets panes hand a dropped file to the same
    /// transcription flow as the menu bar icon.
    var transcribeFile: ((URL) -> Void)?
}

/// The 2.0 main window: a dark hover-expanding icon rail on the left,
/// one roomy content pane on the right. Replaces the old scattered
/// History and Settings windows.
struct MainWindowView: View {
    @ObservedObject var state = MainWindowState.shared

    var body: some View {
        HStack(spacing: 0) {
            Rail(section: $state.section)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1000, minHeight: 640)
        .tint(Brand.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch state.section {
        case .dictations: DictationsPane()
        case .stats: StatsPane()
        case .transcripts: TranscriptsPane()
        case .styles: StylesPane()
        case .dictionary: DictionaryPane()
        case .settings: SettingsPane()
        case .diagnostics: DiagnosticsPane()
        case .privacy: PrivacyPane()
        case .moves: MovesPane()
        }
    }
}

// MARK: - The rail

private struct Rail: View {
    @Binding var section: MainSection
    @State private var expanded = false
    @StateObject private var provider = ProviderStatus()

    private static let railColor = Color(red: 0.075, green: 0.07, blue: 0.063)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                BreathingLogo()
                Text("yapping")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .opacity(expanded ? 1 : 0)
                    .offset(x: expanded ? 0 : -6)
            }
            .padding(.leading, 8)
            .padding(.bottom, 16)

            ForEach(MainSection.allCases) { item in
                RailItem(item: item, active: section == item, expanded: expanded) {
                    section = item
                }
            }

            Spacer(minLength: 8)

            statusPill
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)   // clears the traffic lights
        .padding(.bottom, 14)
        .frame(width: expanded ? 224 : 72, alignment: .leading)
        .clipped()
        .background(Self.railColor)
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                expanded = hovering
            }
        }
        .task {
            while !Task.isCancelled {
                await provider.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var statusPill: some View {
        Group {
            if expanded {
                HStack(spacing: 10) {
                    PulsingDot(ok: provider.ok)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.ok ? "ready to yap" : "provider offline")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(provider.detailLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 5) {
                    PulsingDot(ok: provider.ok)
                    Text(provider.miniLabel)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.05)))
    }
}

private struct RailItem: View {
    let item: MainSection
    let active: Bool
    let expanded: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(item.label)
                    .font(.system(size: 13.5, weight: active ? .bold : .regular))
                    .fixedSize()
                    .opacity(expanded ? 1 : 0)
                    .offset(x: expanded ? 0 : -8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .foregroundStyle(active
                ? Color(red: 0.09, green: 0.08, blue: 0.06)
                : .white.opacity(hovering ? 1 : 0.65))
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(active
                        ? AnyShapeStyle(Brand.accent)
                        : hovering
                            ? AnyShapeStyle(.white.opacity(0.08))
                            : AnyShapeStyle(.clear)))
            .shadow(color: active ? Brand.accent.opacity(0.35) : .clear, radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The six logo bars, gently breathing so the brand always feels alive.
struct BreathingLogo: View {
    @State private var up = false
    private static let heights: [CGFloat] = Brand.barHeights.map { $0 * (20.0 / 15.0) }

    var body: some View {
        HStack(alignment: .center, spacing: 2.6) {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3.2, height: Self.heights[index])
                    .scaleEffect(y: up ? 1.1 : 0.75)
                    .animation(
                        .easeInOut(duration: 1.3)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.35),
                        value: up)
            }
        }
        .frame(height: 20)
        .onAppear { up = true }
    }
}

struct PulsingDot: View {
    var ok = true
    @State private var throb = false

    var body: some View {
        Circle()
            .fill(ok ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .shadow(color: (ok ? Color.green : .orange).opacity(throb ? 0 : 0.5),
                    radius: throb ? 6 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                       value: throb)
            .onAppear { throb = true }
    }
}

/// Live provider health for the rail's status pill.
@MainActor
final class ProviderStatus: ObservableObject {
    @Published var ok = true
    @Published var detailLine = ""
    @Published var miniLabel = ""

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    func refresh() async {
        let config = ConfigStore.shared
        switch config.cleanupProvider {
        case "apple":
            let fallbackUp = Cleanup.appleAvailable ? true : await Cleanup.reachable()
            ok = fallbackUp
            detailLine = "apple intelligence \u{00B7} \(version)"
            miniLabel = "apple"
        case "custom":
            ok = !config.customBaseURL.isEmpty
            let model = config.customModel.isEmpty ? "custom" : config.customModel
            detailLine = "custom \u{00B7} \(model) \u{00B7} \(version)"
            miniLabel = shortModel(model)
        default:
            ok = await Cleanup.reachable()
            detailLine = "ollama \u{00B7} \(config.ollamaModel) \u{00B7} \(version)"
            miniLabel = shortModel(config.ollamaModel)
        }
    }

    /// "qwen3:4b-instruct-2507-q4_K_M" reads as "qwen3" in the collapsed badge.
    private func shortModel(_ model: String) -> String {
        String(model.split(separator: ":").first ?? Substring(model))
    }
}

// MARK: - Shared pane furniture

/// Oversized lowercase title with the orange full stop, plus a quiet subtitle.
struct PaneHeader: View {
    let title: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text(title.lowercased()) + Text(".").foregroundColor(Brand.accent))
                .font(.system(size: 30, weight: .heavy))
                .kerning(-0.5)
            Text(sub)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
    }
}

/// The site's mono microlabel, as a SwiftUI component.
struct MonoLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, design: .monospaced))
            .kerning(1.2)
            .foregroundStyle(Brand.accent)
    }
}

extension View {
    /// The card treatment every pane uses.
    func paneCard() -> some View {
        padding(16)
            .background(RoundedRectangle(cornerRadius: 13).fill(.quaternary.opacity(0.35)))
    }
}

// MARK: - Transcripts pane

struct TranscriptsPane: View {
    @ObservedObject var store = TranscriptStore.shared
    @State private var viewing: TranscriptEntry?

    var body: some View {
        Group {
            if let entry = viewing {
                detail(entry)
            } else {
                list
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 48)
        // The empty state advertises dropping a file, so the pane itself
        // must accept one; a promise in copy is a promise in behavior
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first,
                  let handler = MainWindowState.shared.transcribeFile else { return false }
            handler(url)
            return true
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "transcripts",
                       sub: "listen sessions and transcribed files, with their notes")
            if store.entries.isEmpty {
                Text("Start Listen from the menu bar, drop an audio or video file here, or drop one on the menu bar icon. Finished transcripts land in this pane.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func row(_ entry: TranscriptEntry) -> some View {
        Button {
            viewing = entry
        } label: {
            HStack(spacing: 14) {
                Image(systemName: entry.kind == .listen ? "waveform" : "doc")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Brand.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 13.5, weight: .semibold))
                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) \u{00B7} \(Int(entry.seconds / 60)) min \u{00B7} \(StatsView.compact(entry.words)) words")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.summary.isEmpty ? "TRANSCRIPT" : "NOTES READY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(entry.summary.isEmpty ? Color.secondary : Brand.accent)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(entry.summary.isEmpty
                        ? AnyShapeStyle(.quaternary.opacity(0.5))
                        : AnyShapeStyle(Brand.accent.opacity(0.14))))
            }
            .paneCard()
        }
        .buttonStyle(.plain)
    }

    private func detail(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    viewing = nil
                } label: {
                    Label("Transcripts", systemImage: "chevron.left")
                }
                Spacer()
                Button("Copy") {
                    let contents = entry.summary.isEmpty
                        ? entry.text : entry.summary + "\n\n---\n\n" + entry.text
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(contents, forType: .string)
                }
                Button("Delete", role: .destructive) {
                    store.remove(id: entry.id)
                    viewing = nil
                }
            }
            PaneHeader(title: entry.title,
                       sub: "\(entry.date.formatted(date: .long, time: .shortened)) \u{00B7} \(StatsView.compact(entry.words)) words")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !entry.summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            MonoLabel("Notes")
                            Text(entry.summary).font(.callout).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paneCard()
                    }
                    Text(entry.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Privacy pane

struct PrivacyPane: View {
    @ObservedObject var config = ConfigStore.shared
    @ObservedObject var netLog = NetLog.shared

    private var providerLine: String {
        switch config.cleanupProvider {
        case "apple": return "Apple Intelligence, on this Mac (no network at all)"
        case "custom": return config.customBaseURL.isEmpty
            ? "your custom endpoint (not configured yet)" : config.customBaseURL
        default: return "\(config.ollamaHost) (your Ollama)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(title: "privacy", sub: "the receipts, live from this session")

                VStack(alignment: .leading, spacing: 8) {
                    Text("This app can reach exactly three things, and nothing else")
                        .font(.system(size: 14, weight: .bold))
                    bullet("Your cleanup provider: \(providerLine)")
                    bullet("api.github.com, once a day, to check for updates")
                    bullet("github.com, only when you click Update Now")
                    Text("Your voice and transcripts never leave this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .paneCard()

                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel("Connections this session")
                    if netLog.events.isEmpty {
                        Text("None yet.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(netLog.events.prefix(10))) { event in
                            HStack(spacing: 6) {
                                Text(event.date, style: .time)
                                Text(event.host).fontWeight(.medium)
                                Text(event.purpose)
                                if !event.ok { Text("failed").foregroundStyle(.red) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .paneCard()

                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel("On disk")
                    bullet("History, stats, and transcripts are written with owner-only permissions")
                    bullet("Stats keep numbers, never your words")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .paneCard()

                HStack(spacing: 14) {
                    Text("yapping \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                    Link("github.com/angad-kandhari/yapping",
                         destination: URL(string: "https://github.com/angad-kandhari/yapping")!)
                    Spacer()
                    Button("Reveal Log File") { Log.reveal() }
                }
                .font(.callout)
                .padding(.top, 4)
            }
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}").foregroundStyle(Brand.accent).bold()
            Text(text)
        }
        .font(.callout)
    }
}
