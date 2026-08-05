import SwiftUI

/// The stats pane: the numbers a dictation app can show you, computed and
/// stored only on this Mac. Numbers only; stats never keep your words.
struct StatsPane: View {
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "stats",
                       sub: "computed and stored only on this Mac \u{00B7} stats never keep your words")
                .padding(.horizontal, 36)
                .padding(.top, 48)
            StatsView()
        }
    }
}

struct StatsView: View {
    @ObservedObject var store = StatsStore.shared

    var body: some View {
        if store.data.totalSessions == 0 {
            Text("Dictate once and numbers appear.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tiles
                    secondTiles
                    HStack(alignment: .top, spacing: 14) {
                        heatmap
                        perApp.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        paceTrend
                        hourHistogram.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    perStyle
                    Text("All numbers live only on this Mac; stats never keep your words. Time saved assumes typing at 40 words a minute. Hour and style figures start from version 2.5, so they cannot reach back over older dictations.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 24)
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

    /// Numbers the store has recorded since 1.6 and never shown.
    private var secondTiles: some View {
        let data = store.data
        let perSession = data.totalSessions > 0 ? data.totalWords / data.totalSessions : 0
        return HStack(spacing: 10) {
            tile(data.since.formatted(date: .abbreviated, time: .omitted), "yapping since")
            tile("\(data.totalSessions)", "dictations")
            tile("\(perSession)", "words per dictation")
            tile(Self.duration(minutes: data.totalSeconds / 60), "spent talking")
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
            MonoLabel("Last 26 weeks")
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
        .paneCard()
    }

    private func cellColor(words: Int, peak: Int) -> Color {
        guard words > 0 else { return Color.primary.opacity(0.06) }
        let intensity = Double(words) / Double(peak)
        return Brand.accent.opacity(0.3 + 0.7 * min(1, intensity + 0.05))
    }

    // MARK: - Pace over time

    /// Days without enough speaking time to measure are drawn as gaps, not
    /// zeros. A zero would claim the user slowed to a halt when the truth is
    /// that we simply cannot know (backfilled days carry no duration).
    private var paceTrend: some View {
        let series = StatsStore.wpmSeries(days: store.data.days)
        let values = series.compactMap { $0.wpm }
        let peak = max(values.max() ?? 1, 1)
        let floor = min(values.min() ?? 0, peak)
        return VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Pace, last 30 days")
            if values.isEmpty {
                Text("Not enough speaking time measured yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 60, alignment: .center)
            } else {
                GeometryReader { geo in
                    let step = series.count > 1 ? geo.size.width / CGFloat(series.count - 1) : 0
                    let span = max(peak - floor, 1)
                    ZStack(alignment: .topLeading) {
                        Path { path in
                            var started = false
                            for (index, point) in series.enumerated() {
                                guard let wpm = point.wpm else {
                                    started = false  // break the line at a gap
                                    continue
                                }
                                let x = CGFloat(index) * step
                                let y = geo.size.height * (1 - CGFloat((wpm - floor) / span))
                                if started {
                                    path.addLine(to: CGPoint(x: x, y: y))
                                } else {
                                    path.move(to: CGPoint(x: x, y: y))
                                    started = true
                                }
                            }
                        }
                        .stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }
                }
                .frame(height: 60)
                HStack {
                    Text("\(Int(floor)) wpm").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(Int(peak)) wpm").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .paneCard()
    }

    // MARK: - When you yap

    private var hourHistogram: some View {
        let hours = StatsStore.hourHistogram(days: store.data.days)
        let peak = max(hours.max() ?? 0, 1)
        let peakHour = hours.firstIndex(of: hours.max() ?? 0) ?? 0
        let hasData = hours.contains { $0 > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            MonoLabel("When you yap")
            if !hasData {
                Text("Starts filling in from 2.5 onward.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 60, alignment: .center)
            } else {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(hours[hour] > 0
                                  ? Brand.accent.opacity(0.35 + 0.65 * Double(hours[hour]) / Double(peak))
                                  : Color.primary.opacity(0.06))
                            .frame(height: max(3, 60 * CGFloat(hours[hour]) / CGFloat(peak)))
                    }
                }
                .frame(height: 60)
                Text("Most words around \(Self.hourLabel(peakHour)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .paneCard()
    }

    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "midnight"
        case 12: return "noon"
        case 1...11: return "\(hour) am"
        default: return "\(hour - 12) pm"
        }
    }

    // MARK: - Per-style

    private var perStyle: some View {
        let top = Array(store.data.styles.sorted { $0.value.words > $1.value.words }.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Which style wrote it")
            if top.isEmpty {
                Text("Starts filling in from 2.5 onward.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let peak = max(top.first?.value.words ?? 1, 1)
                ForEach(top, id: \.key) { name, stat in
                    HStack(spacing: 10) {
                        Text(name).font(.callout).lineLimit(1)
                            .frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Brand.accent.opacity(0.85))
                                .frame(width: max(4, geo.size.width * CGFloat(stat.words) / CGFloat(peak)))
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 10)
                        Text("\(stat.sessions)x").font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 40, alignment: .trailing)
                        Text(Self.compact(stat.words)).font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .paneCard()
    }

    // MARK: - Per-app

    private var perApp: some View {
        let top = Array(
            store.data.apps.sorted { $0.value.words > $1.value.words }.prefix(8))
        let peak = max(top.first?.value.words ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Where you yap")
            ForEach(top, id: \.key) { name, stat in
                HStack(spacing: 10) {
                    Text(name)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Brand.accent.opacity(0.85))
                            .frame(width: max(
                                4, geo.size.width * CGFloat(stat.words) / CGFloat(peak)))
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 10)
                    Text("\(stat.sessions)x").font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 40, alignment: .trailing)
                    Text(Self.compact(stat.words))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
        .paneCard()
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
