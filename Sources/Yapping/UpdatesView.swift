import AppKit
import SwiftUI

/// The Updates window: an honest answer to "am I on the latest?".
/// Up to date shows a green check; behind shows every release you are
/// missing, with its release notes, and a download button.
struct UpdatesView: View {
    private enum CheckState {
        case checking
        case upToDate
        case behind([Release])
        case updating(String)
        case updateFailed(String, [Release])
        case failed
    }

    @State private var state: CheckState = .checking
    @State private var checkedAt: Date?

    var body: some View {
        BrandChrome(title: "updates") {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 520, height: 440)
        .task { await check() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .checking:
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking GitHub...").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .upToDate:
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("You are on the latest")
                    .font(.title3.bold())
                Text("Yapping \(UpdateCheck.currentVersion)")
                    .foregroundStyle(.secondary)
                if let checkedAt {
                    Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Button("Check Again") {
                    state = .checking
                    Task { await check() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .behind(let releases):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Yapping \(releases.first?.version ?? "") is available")
                            .font(.title3.bold())
                        Text("You have \(UpdateCheck.currentVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("Update Now") { install(releases) }
                            .buttonStyle(.borderedProminent)
                        Text("Downloads, verifies, and relaunches.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(releases) { release in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(release.version)
                                        .font(.system(.subheadline, weight: .bold))
                                        .foregroundStyle(Brand.accent)
                                    if let date = release.publishedAt {
                                        Text(date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                Text(notesText(release.notes))
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        Link("View all releases on GitHub",
                             destination: UpdateCheck.releasesPage)
                            .font(.caption)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .updating(let status):
            VStack(spacing: 12) {
                ProgressView()
                Text(status).foregroundStyle(.secondary)
                Text("The app restarts itself when this finishes.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .updateFailed(let message, let releases):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Could not update").font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                HStack(spacing: 12) {
                    Button("Try Again") { install(releases) }
                    Button("Download from GitHub") {
                        NSWorkspace.shared.open(
                            releases.first?.url ?? UpdateCheck.releasesPage)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Could not reach GitHub").font(.headline)
                Text("Check your connection and try again.")
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    state = .checking
                    Task { await check() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func install(_ releases: [Release]) {
        guard let latest = releases.first else { return }
        state = .updating("Preparing...")
        Task {
            do {
                try await Updater.install(latest) { status in
                    state = .updating(status)
                }
            } catch {
                await MainActor.run {
                    state = .updateFailed(error.localizedDescription, releases)
                }
            }
        }
    }

    private func check() async {
        let result = await UpdateCheck.newerReleases()
        await MainActor.run {
            checkedAt = Date()
            switch result {
            case nil: state = .failed
            case .some(let releases) where releases.isEmpty: state = .upToDate
            case .some(let releases): state = .behind(releases)
            }
        }
    }

    /// Release notes are markdown; render the readable parts.
    private func notesText(_ markdown: String) -> AttributedString {
        let cleaned = markdown
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "\r", with: "")
        if let rendered = try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return rendered
        }
        return AttributedString(cleaned)
    }
}
