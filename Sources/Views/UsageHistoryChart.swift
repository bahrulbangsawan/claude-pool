import Charts
import SwiftUI

/// Observed history, one continuous line per window. Each reported value holds until the next
/// observation (a step), and drops to 0 at a reset that has passed; nothing between observations is
/// estimated. Hover snaps to the nearest observation.
struct UsageHistoryChart: View {
    enum Range: String, CaseIterable, Identifiable {
        case day = "24 Hours"
        case week = "7 Days"

        var id: String { rawValue }
        var seconds: TimeInterval { self == .day ? 24 * 60 * 60 : 7 * 24 * 60 * 60 }
    }

    struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let window: UsageWindowKind
        /// False for the points added at a reset (the held value, then 0).
        let observed: Bool
    }

    static let seriesColors: [UsageWindowKind: Color] = [.fiveHour: .accentColor, .sevenDay: .purple]

    @Environment(AppModel.self) private var model
    let profileID: UUID
    /// Snapshot rendering only: pins the hover tooltip at this time.
    var previewHoverDate: Date?
    @State private var range: Range = .day
    @State private var hovered: UsageHistoryEntry?

    var body: some View {
        let now = model.usageStore.now
        let start = now.addingTimeInterval(-range.seconds)
        // Depends on the snapshot so the chart refreshes when the collector writes.
        let _ = model.usageStore.snapshot(for: profileID)
        let entries = model.usageStore.history(for: profileID, since: start)
        let points = Self.points(from: entries, now: now)
        let resets = Self.resets(from: entries, in: start...now)

        Card(title: "History", subtitle: "Each reported value holds until the next · hover for details") {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            if points.isEmpty {
                EmptyChart(range: range)
            } else {
                stats(entries)
                chart(points: points, resets: resets, domain: start...now)
                legend
            }
        }
        .onChange(of: range) { hovered = nil }
        .onAppear {
            if let previewHoverDate {
                hovered = Self.nearest(to: previewHoverDate, in: model.usageStore.history(for: profileID, since: start))
            }
        }
    }

    // MARK: Chart

    private func chart(points: [Point], resets: [Date], domain: ClosedRange<Date>) -> some View {
        Chart {
            ForEach(resets, id: \.self) { reset in
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Used", point.value),
                    series: .value("Window", point.window.title)
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(Self.seriesColors[point.window] ?? .accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .accessibilityLabel("\(point.window.title), \(point.observed ? "" : "reset, ")\(point.date.formatted(date: .abbreviated, time: .shortened))")
                .accessibilityValue("\(UsageFormatting.percent(point.value)) percent")
            }
            if let hovered {
                RuleMark(x: .value("Selected", hovered.date))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        HoverCard(entry: hovered)
                    }
                ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                    if let value = kind == .fiveHour ? hovered.fh : hovered.sd {
                        PointMark(x: .value("Selected", hovered.date), y: .value("Used", value))
                            .foregroundStyle(Self.seriesColors[kind] ?? .accentColor)
                            .symbolSize(70)
                    }
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").monospacedDigit() }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .day ? 6 : 7)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: range == .day ? .dateTime.hour() : .dateTime.weekday(.abbreviated))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geometry[frame].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                hovered = Self.nearest(to: date, in: model.usageStore.history(for: profileID, since: domain.lowerBound))
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .frame(height: 240)
    }

    private var legend: some View {
        HStack(spacing: Space.md) {
            ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                Label {
                    Text(kind.title)
                } icon: {
                    Capsule().fill(Self.seriesColors[kind] ?? .accentColor).frame(width: 14, height: 3)
                }
                .labelStyle(.titleAndIcon)
            }
            Label {
                Text("Observed reset")
            } icon: {
                Rectangle().fill(.clear).frame(width: 1, height: 12)
                    .overlay(Rectangle().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            }
            Spacer()
        }
        .font(.meta)
        .foregroundStyle(.secondary)
    }

    // MARK: Stats (observed values only)

    private func stats(_ entries: [UsageHistoryEntry]) -> some View {
        let peakFive = entries.compactMap(\.fh).max()
        let peakSeven = entries.compactMap(\.sd).max()
        let resets = Set(entries.compactMap(\.fhr)).count
        return HStack(spacing: Space.sm) {
            Stat(title: "Observations", value: "\(entries.count)")
            Stat(title: "Peak 5-hour", value: peakFive.map(UsageFormatting.percentText) ?? "—")
            Stat(title: "Peak 7-day", value: peakSeven.map(UsageFormatting.percentText) ?? "—")
            Stat(title: "5-hour windows", value: resets == 0 ? "—" : "\(resets)")
        }
    }

    // MARK: Data

    /// Reset times closer than this are the same window (as in the collector).
    static let sameWindowTolerance: TimeInterval = 60

    /// For each window, the observations in order. When a window's reset has passed before the next
    /// observation (or before `now`), its last value is held to the reset, then drops to 0 there.
    static func points(from entries: [UsageHistoryEntry], now: Date) -> [Point] {
        var points: [Point] = []
        for kind in UsageWindowKind.allCases {
            func add(_ time: TimeInterval, _ value: Double, observed: Bool) {
                points.append(Point(id: "\(kind.rawValue)-\(points.count)", date: Date(timeIntervalSince1970: time),
                                    value: value, window: kind, observed: observed))
            }
            var last: (value: Double, reset: TimeInterval)?
            for entry in entries {
                guard let value = kind == .fiveHour ? entry.fh : entry.sd,
                      let reset = kind == .fiveHour ? entry.fhr : entry.sdr else { continue }
                if let previous = last, abs(previous.reset - reset) >= sameWindowTolerance, previous.reset <= entry.t {
                    add(previous.reset, previous.value, observed: false)
                    add(previous.reset, 0, observed: false)
                }
                add(entry.t, value, observed: true)
                last = (value, reset)
            }
            if let previous = last, previous.reset <= now.timeIntervalSince1970 {
                add(previous.reset, previous.value, observed: false)
                add(previous.reset, 0, observed: false)
            }
        }
        return points
    }

    static func resets(from entries: [UsageHistoryEntry], in range: ClosedRange<Date>) -> [Date] {
        let all = entries.flatMap { [$0.fhr, $0.sdr].compactMap { $0 } }
        return Set(all).map { Date(timeIntervalSince1970: $0) }.filter(range.contains).sorted()
    }

    static func nearest(to date: Date, in entries: [UsageHistoryEntry]) -> UsageHistoryEntry? {
        entries.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

/// Empty state on the type scale: what this is, and what fills it.
private struct EmptyChart: View {
    let range: UsageHistoryChart.Range

    var body: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No observations in the last \(range == .day ? "24 hours" : "7 days")")
                .font(.rowTitle.weight(.medium))
            Text("History fills in as a claude session with this profile sends messages.")
                .font(.rowDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
    }
}

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.meta).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.metric)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Tooltip shown while hovering the chart: time and each value observed at that moment.
private struct HoverCard: View {
    let entry: UsageHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.meta.weight(.semibold))
            ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                if let value = kind == .fiveHour ? entry.fh : entry.sd {
                    HStack(spacing: Space.xs) {
                        Circle().fill(UsageHistoryChart.seriesColors[kind] ?? .accentColor).frame(width: 7, height: 7)
                        Text(kind.title).foregroundStyle(.secondary)
                        Spacer(minLength: Space.sm)
                        Text(UsageFormatting.percentText(value)).monospacedDigit()
                    }
                    .font(.meta)
                }
            }
        }
        .padding(Space.xs)
        .frame(minWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).strokeBorder(Color.cardStroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
