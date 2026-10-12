import Charts
import SwiftUI

enum TokenKind: String, CaseIterable, Identifiable {
    case input = "Input"
    case output = "Output"
    case cacheCreation = "Cache write"
    case cacheRead = "Cache read"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .input: .blue
        case .output: .green
        case .cacheCreation: .orange
        case .cacheRead: .purple
        }
    }

    func value(_ totals: TokenTotals) -> Int64 {
        switch self {
        case .input: totals.input
        case .output: totals.output
        case .cacheCreation: totals.cacheCreation
        case .cacheRead: totals.cacheRead
        }
    }
}

enum TokenFormat {
    /// "1.2M", "34.5k", "980".
    static func compact(_ value: Int64) -> String {
        let v = Double(value)
        switch abs(v) {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 10_000...: return String(format: "%.0fk", v / 1_000)
        case 1_000...: return String(format: "%.1fk", v / 1_000)
        default: return "\(value)"
        }
    }

    static func exact(_ value: Int64) -> String { value.formatted(.number) }
}

/// Recorded token usage per period, account and model. Token counts come from Claude Code's
/// own per-request records on this Mac; subscription quota is shown separately below.
struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @State private var hiddenKinds: Set<TokenKind> = []
    @State private var hovered: AnalyticsReport.Point?

    var body: some View {
        @Bindable var store = model.analyticsStore
        Page {
            PageHeader(title: "Usage Analytics", subtitle: "Tokens Claude Code recorded on this Mac, per request") {
                Picker("Period", selection: $store.period) {
                    ForEach(AnalyticsPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button {
                    model.analyticsStore.rescan()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read new conversation records now")
            }
        } content: {
            filters
            indexStatus
            if let report = store.report {
                summary(report)
                chart(report)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Space.md) {
                        breakdown(title: "By account", shares: report.byProfile, total: report.current.total)
                        breakdown(title: "By model", shares: report.byModel, total: report.current.total)
                    }
                    VStack(spacing: Space.md) {
                        breakdown(title: "By account", shares: report.byProfile, total: report.current.total)
                        breakdown(title: "By model", shares: report.byModel, total: report.current.total)
                    }
                }
            } else if case .failed = store.status {
                EmptyView()
            } else {
                Card { ProgressView("Loading usage…").frame(maxWidth: .infinity).padding(Space.lg) }
            }
            quotaCard
            Text("Totals count every token the API reported for each response: input + output + cache write + cache read. Each response is counted once even though Claude Code writes it several times. Usage on claude.ai, the desktop app or other computers isn't included.")
                .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Filters and status

    private var filters: some View {
        @Bindable var store = model.analyticsStore
        return HStack(spacing: Space.sm) {
            Picker("Account", selection: $store.profileFilter) {
                Text("All accounts").tag(UUID?.none)
                Divider()
                ForEach(model.profiles) { profile in
                    Text(accountLabel(profile)).tag(Optional(profile.id))
                }
            }
            .frame(maxWidth: 300)
            Picker("Model", selection: $store.modelFilter) {
                Text("All models").tag(String?.none)
                Divider()
                ForEach(store.availableModels, id: \.self) { Text(ModelName.display($0)).tag(Optional($0)) }
                if let selected = store.modelFilter, !store.availableModels.contains(selected) {
                    Text(ModelName.display(selected)).tag(Optional(selected))
                }
            }
            .frame(maxWidth: 240)
            Spacer()
        }
    }

    private func accountLabel(_ profile: Profile) -> String {
        if let email = model.authStore.status(for: profile.id)?.email { return "\(profile.name) — \(email)" }
        return profile.name
    }

    @ViewBuilder
    private var indexStatus: some View {
        switch model.analyticsStore.status {
        case let .indexing(done, total):
            HStack(spacing: Space.xs) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160)
                Text("Reading conversation records… \(done) of \(total) files. The first read can take a minute; later updates are incremental.")
                    .font(.meta).foregroundStyle(.secondary)
            }
        case let .failed(message):
            InlineMessage(kind: .error, text: message) {
                Button("Retry") { model.analyticsStore.rescan() }.controlSize(.small)
            }
        case .idle:
            if let last = model.analyticsStore.lastIndexedAt {
                Label("Updated \(model.formatting.age(since: last)) · \(model.analyticsStore.indexedFiles) files · refreshes automatically when Claude Code is active",
                      systemImage: "clock")
                    .font(.meta).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Summary

    private func summary(_ report: AnalyticsReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Space.md)], spacing: Space.md) {
            SummaryTile(title: "Total tokens", value: report.current.total, previous: report.previous.total, partial: report.previousIsPartial,
                        help: "Input + output + cache write + cache read")
            SummaryTile(title: "Input", value: report.current.input, previous: report.previous.input, partial: report.previousIsPartial, tint: TokenKind.input.color)
            SummaryTile(title: "Output", value: report.current.output, previous: report.previous.output, partial: report.previousIsPartial, tint: TokenKind.output.color)
            SummaryTile(title: "Cache write", value: report.current.cacheCreation, previous: report.previous.cacheCreation, partial: report.previousIsPartial,
                        tint: TokenKind.cacheCreation.color, help: "Tokens written to the prompt cache")
            SummaryTile(title: "Cache read", value: report.current.cacheRead, previous: report.previous.cacheRead, partial: report.previousIsPartial,
                        tint: TokenKind.cacheRead.color, help: "Tokens served from the prompt cache")
            SummaryTile(title: "Requests", value: report.current.requests, previous: report.previous.requests, partial: report.previousIsPartial,
                        help: "API responses recorded (each counted once)")
        }
    }

    // MARK: Chart

    private func chart(_ report: AnalyticsReport) -> some View {
        let visible = TokenKind.allCases.filter { !hiddenKinds.contains($0) }
        return Card(title: "Over time", subtitle: bucketTitle(report.period) + " · local time · hover for exact values") {
            EmptyView()
        } content: {
            if report.current.requests == 0 {
                VStack(spacing: Space.xs) {
                    Image(systemName: "chart.bar").font(.title2).foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text("No recorded usage in this period").font(.rowDetail).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                let keys = report.series.map(Self.key)
                let labelEvery = max(1, report.series.count / 7)
                Chart {
                    ForEach(report.series) { point in
                        ForEach(visible) { kind in
                            BarMark(
                                x: .value("Time", Self.key(point)),
                                y: .value("Tokens", kind.value(point.totals)),
                                width: .ratio(0.8)
                            )
                            .foregroundStyle(by: .value("Type", kind.rawValue))
                            .opacity(hovered == nil || hovered?.start == point.start ? 1 : 0.45)
                        }
                    }
                    if let hovered {
                        RuleMark(x: .value("Time", Self.key(hovered)))
                            .foregroundStyle(Color.secondary.opacity(0.0))
                            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                BucketTooltip(point: hovered, period: report.period, kinds: visible)
                            }
                    }
                }
                .chartXScale(domain: keys)
                .chartForegroundStyleScale(domain: TokenKind.allCases.map(\.rawValue), range: TokenKind.allCases.map(\.color))
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisValueLabel { Text(TokenFormat.compact(value.as(Int64.self) ?? 0)).monospacedDigit() }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: keys.enumerated().filter { $0.offset % labelEvery == 0 }.map(\.element)) { value in
                        AxisValueLabel {
                            if let key = value.as(String.self), let point = report.series.first(where: { Self.key($0) == key }) {
                                Text(Self.axisLabel(point.start, period: report.period))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    guard let frame = proxy.plotFrame else { return }
                                    if let key: String = proxy.value(atX: location.x - geometry[frame].origin.x) {
                                        hovered = report.series.first { Self.key($0) == key }
                                    }
                                case .ended:
                                    hovered = nil
                                }
                            }
                    }
                }
                .frame(height: 240)
                .accessibilityLabel("Token usage chart, \(report.period.title)")
                legend
            }
        }
        .onChange(of: report.period) { hovered = nil }
    }

    private var legend: some View {
        HStack(spacing: Space.md) {
            ForEach(TokenKind.allCases) { kind in
                let hidden = hiddenKinds.contains(kind)
                Button {
                    if hidden { hiddenKinds.remove(kind) } else if hiddenKinds.count < TokenKind.allCases.count - 1 { hiddenKinds.insert(kind) }
                } label: {
                    Label {
                        Text(kind.rawValue)
                    } icon: {
                        RoundedRectangle(cornerRadius: 2).fill(kind.color.opacity(hidden ? 0.25 : 1)).frame(width: 12, height: 12)
                    }
                    .foregroundStyle(hidden ? .tertiary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(kind.rawValue) series")
                .accessibilityValue(hidden ? "hidden" : "shown")
                .help(hidden ? "Show \(kind.rawValue)" : "Hide \(kind.rawValue) (cache reads are often much larger than the rest)")
            }
            Spacer()
        }
        .font(.meta)
    }

    /// One evenly spaced category per bucket, so 6-hour and daily bars fill their slot.
    static func key(_ point: AnalyticsReport.Point) -> String {
        String(Int(point.start.timeIntervalSince1970))
    }

    static func axisLabel(_ date: Date, period: AnalyticsPeriod) -> String {
        switch period {
        case .day: date.formatted(.dateTime.hour())
        case .week: date.formatted(.dateTime.weekday(.abbreviated).day())
        case .month: date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private func bucketTitle(_ period: AnalyticsPeriod) -> String {
        switch period {
        case .day: "Hourly"
        case .week: "Every 6 hours"
        case .month: "Daily"
        }
    }

    // MARK: Breakdown

    private func breakdown(title: String, shares: [AnalyticsReport.Share], total: Int64) -> some View {
        Card(title: title) {
            if shares.isEmpty {
                Text("No data").font(.rowDetail).foregroundStyle(.secondary)
            } else {
                VStack(spacing: Space.sm) {
                    ForEach(shares) { share in
                        let fraction = total > 0 ? Double(share.totals.total) / Double(total) : 0
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(share.label).font(.rowDetail).lineLimit(1)
                                Spacer()
                                Text(TokenFormat.compact(share.totals.total)).font(.rowDetail.monospacedDigit())
                                Text("\(Int((fraction * 100).rounded()))%").font(.meta.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            UsageBar(content: .value(fraction * 100, stale: false), height: 5)
                                .tint(.accentColor)
                            Text("in \(TokenFormat.compact(share.totals.input)) · out \(TokenFormat.compact(share.totals.output)) · cache w \(TokenFormat.compact(share.totals.cacheCreation)) · cache r \(TokenFormat.compact(share.totals.cacheRead)) · \(share.totals.requests.formatted()) requests")
                                .font(.meta.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .help("\(share.label): \(TokenFormat.exact(share.totals.total)) tokens")
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Quota

    private var quotaCard: some View {
        Card(title: "Subscription windows", subtitle: "Reported by Claude Code's status line · not derived from the token counts above") {
            VStack(spacing: Space.sm) {
                ForEach(model.profiles) { profile in
                    let five = model.usageState(profile, .fiveHour)
                    let seven = model.usageState(profile, .sevenDay)
                    HStack(spacing: Space.sm) {
                        ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 20)
                        Text(profile.name).font(.rowDetail).lineLimit(1).frame(width: 140, alignment: .leading)
                        CompactUsageBar(kind: .fiveHour, state: five, formatting: model.formatting, barWidth: 70)
                        CompactUsageBar(kind: .sevenDay, state: seven, formatting: model.formatting, barWidth: 70)
                        Spacer(minLength: Space.xs)
                        AvailabilityBadge(availability: model.availability(profile), formatting: model.formatting)
                            .frame(maxWidth: 280, alignment: .trailing)
                    }
                    if profile.id != model.profiles.last?.id { Divider() }
                }
            }
        }
    }
}

private struct SummaryTile: View {
    let title: String
    let value: Int64
    let previous: Int64
    let partial: Bool
    var tint: Color = .primary
    var help: String?

    var body: some View {
        let change = AnalyticsReport.change(value, previous)
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xxs) {
                if tint != .primary { Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true) }
                Text(title).font(.meta).foregroundStyle(.secondary)
            }
            Text(TokenFormat.compact(value)).font(.metric).help(TokenFormat.exact(value))
            Group {
                if let change {
                    Label("\(change >= 0 ? "+" : "")\(Int(change.rounded()))% vs previous\(partial ? " (partial data)" : "")",
                          systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                } else {
                    Text(previous == 0 && value > 0 ? "No usage in previous period" : "—")
                }
            }
            .font(.meta.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("Previous period: \(TokenFormat.exact(previous))")
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.cardStroke.opacity(0.6), lineWidth: 0.5))
        .help(help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(TokenFormat.exact(value))")
    }
}

private struct BucketTooltip: View {
    let point: AnalyticsReport.Point
    let period: AnalyticsPeriod
    let kinds: [TokenKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(range).font(.meta.weight(.semibold))
            ForEach(kinds) { kind in
                HStack(spacing: Space.xs) {
                    Circle().fill(kind.color).frame(width: 7, height: 7)
                    Text(kind.rawValue)
                    Spacer(minLength: Space.sm)
                    Text(TokenFormat.exact(kind.value(point.totals))).monospacedDigit()
                }
            }
            Divider()
            HStack {
                Text("Total")
                Spacer(minLength: Space.sm)
                Text(TokenFormat.exact(point.totals.total)).monospacedDigit()
            }
            HStack {
                Text("Requests")
                Spacer(minLength: Space.sm)
                Text(point.totals.requests.formatted()).monospacedDigit()
            }
        }
        .font(.meta)
        .padding(Space.xs)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.inner))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).strokeBorder(Color.cardStroke, lineWidth: 0.5))
    }

    private var range: String {
        switch period {
        case .day, .week:
            "\(point.start.formatted(date: .abbreviated, time: .shortened)) – \(point.end.formatted(date: .omitted, time: .shortened))"
        case .month:
            point.start.formatted(date: .complete, time: .omitted)
        }
    }
}
