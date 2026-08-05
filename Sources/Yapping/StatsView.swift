import SwiftUI

/// The stats tab: everything Wispr Flow's dashboard shows, computed and
/// stored only on this Mac. Numbers only; stats never keep your words.
struct StatsView: View {
    @ObservedObject var store = StatsStore.shared

    var body: some View {
        if store.data.totalSessions == 0 {
            Text("Dictate once and numbers appear.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    tiles
                    heatmap
                    perApp
                    Text("All numbers live only on this Mac; stats never keep your words. Time saved assumes typing at 40 words a minute.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(20)
            }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        let streaks = StatsStore.streaks(dayKeys: Set(store.data.days.keys))
        let wpm = StatsStore.wpm(
            words: store.data.totalWords, seconds: store.data.totalSeconds)
        let saved = StatsStore.minutesSaved(
            words: store.data.totalWords, seconds: store.data.totalSeconds)
        return HStack(spacing: 10) {
            tile(Self.compact(store.data.totalWords), "words dictated")
            tile(wpm > 0 ? String(Int(wpm)) : "\u{2013}", "words per minute")
            tile(Self.duration(minutes: saved), "saved vs typing")
            tile("\(streaks.current)",
                 streaks.longest > streaks.current
                     ? "day streak (best \(streaks.longest))" : "day streak")
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.accent)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    // MARK: - Heatmap

    private var heatmap: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days: [Date] = (0..<182).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }.reversed()
        let counts = days.map { store.data.days[StatsStore.dayKey($0)]?.words ?? 0 }
        let peak = max(counts.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("LAST 26 WEEKS")
                .font(.caption.bold()).foregroundStyle(Brand.accent)
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<26, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { day in
                            let index = week * 7 + day
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cellColor(
                                    words: index < counts.count ? counts[index] : 0,
                                    peak: peak))
                                .frame(width: 11, height: 11)
                        }
                    }
                }
            }
        }
    }

    private func cellColor(words: Int, peak: Int) -> Color {
        guard words > 0 else { return Color.primary.opacity(0.06) }
        let intensity = Double(words) / Double(peak)
        return Brand.accent.opacity(0.3 + 0.7 * min(1, intensity + 0.05))
    }

    // MARK: - Per-app

    private var perApp: some View {
        let top = Array(
            store.data.apps.sorted { $0.value.words > $1.value.words }.prefix(8))
        let peak = max(top.first?.value.words ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("WHERE YOU YAP")
                .font(.caption.bold()).foregroundStyle(Brand.accent)
            ForEach(top, id: \.key) { name, stat in
                HStack(spacing: 10) {
                    Text(name)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(width: 140, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Brand.accent.opacity(0.85))
                            .frame(width: max(
                                4, geo.size.width * CGFloat(stat.words) / CGFloat(peak)))
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 10)
                    Text(Self.compact(stat.words))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Formatting

    static func compact(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fm", Double(count) / 1_000_000)
        case 10_000...:
            return String(format: "%.0fk", Double(count) / 1_000)
        case 1_000...:
            return String(format: "%.1fk", Double(count) / 1_000)
        default:
            return "\(count)"
        }
    }

    static func duration(minutes: Double) -> String {
        guard minutes >= 1 else { return "\u{2013}" }
        let total = Int(minutes)
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
    }
}
