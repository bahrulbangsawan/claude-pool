import SwiftUI

/// Bar / ring tint for a reported value: accent < 70%, orange 70–89%, red ≥ 90%.
/// The percentage is always printed beside it, so colour is never the only cue.
func usageTint(_ percent: Double) -> Color {
    switch UsageFormatting.level(for: percent) {
    case .normal: .accentColor
    case .elevated: .statusWarn
    case .critical: .statusFail
    }
}

/// Horizontal bar. Filled only with a reported value; "reset passed" is an empty outline, never 0%.
struct UsageBar: View {
    enum Content {
        case value(Double, stale: Bool)
        case outline
    }

    let content: Content
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                switch content {
                case let .value(percent, stale):
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(usageTint(percent))
                        .frame(width: max(height, proxy.size.width * min(max(percent / 100, 0), 1)))
                        .opacity(stale ? 0.45 : 1)
                case .outline:
                    Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One window in a single line: `5h ▓▓░░ 23%`. Used in the menu panel and the sidebar.
struct CompactUsageBar: View {
    let kind: UsageWindowKind
    let state: UsageWindowState
    let formatting: UsageFormatting
    var barWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: Space.xxs) {
            Text(kind.shortLabel)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            switch state {
            case let .fresh(window, _), let .stale(window, _):
                UsageBar(content: .value(window.usedPercentage, stale: state.isStale), height: 5)
                    .frame(width: barWidth)
                Text(UsageFormatting.percentText(window.usedPercentage))
                    .font(.meta.monospacedDigit())
                    .foregroundStyle(state.isStale ? .secondary : .primary)
                    .fixedSize()
            case .resetPassed:
                UsageBar(content: .outline, height: 5).frame(width: barWidth)
                Text("reset").font(.meta).foregroundStyle(.secondary).fixedSize()
            default:
                Text(Self.shortText(state)).font(.meta).foregroundStyle(.secondary).fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatting.accessibilityLabel(state, kind: kind))
    }

    static func shortText(_ state: UsageWindowState) -> String {
        switch state {
        case .noData: "no data"
        case .notReported: "n/a"
        case .signedOut: "signed out"
        case .trackingOff: "off"
        default: ""
        }
    }
}

/// Observation age with a clock icon and an explicit "as of" when stale (not colour alone).
struct ObservationLabel: View {
    let observedAt: Date
    let stale: Bool
    let formatting: UsageFormatting
    /// Shorter text for tight rows: "as of 40m" instead of "as of 40m ago".
    var compact = false

    var body: some View {
        let age = formatting.age(since: observedAt)
        let shortAge = compact && age.hasSuffix(" ago") ? String(age.dropLast(4)) : age
        Label {
            Text(stale ? "as of \(shortAge)" : age)
        } icon: {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
        }
        .labelStyle(.titleAndIcon)
        .font(.meta)
        .foregroundStyle(stale ? Color.statusWarn : Color.secondary)
        .fixedSize()
        .help(stale ? UsageFormatting.staleFootnote : "Observed \(observedAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityLabel(stale ? "Stale, observed \(formatting.age(since: observedAt))" : "Observed \(formatting.age(since: observedAt))")
    }
}

/// A window as a card row: label + value, bar, reset line. Non-value states show their text and action.
struct UsageMeter: View {
    let kind: UsageWindowKind
    let state: UsageWindowState
    let formatting: UsageFormatting
    var onEnableTracking: (() -> Void)?
    var onSignIn: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title).font(.rowDetail.weight(.medium))
                Spacer()
                if let window = state.displayedWindow {
                    Text(UsageFormatting.percentText(window.usedPercentage))
                        .font(.metric)
                        .foregroundStyle(state.isStale ? .secondary : .primary)
                }
            }
            switch state {
            case let .fresh(window, _), let .stale(window, _):
                UsageBar(content: .value(window.usedPercentage, stale: state.isStale), height: 6)
                Text("\(UsageFormatting.percent(window.usedPercentage) >= 100 ? "Limit reached" : UsageFormatting.remainingText(window)) · \(formatting.resetText(window, kind: kind))")
                    .font(.meta.monospacedDigit())
                    .foregroundStyle(UsageFormatting.percent(window.usedPercentage) >= 100 ? Color.statusFail : Color.secondary)
            case let .resetPassed(resetAt):
                UsageBar(content: .outline, height: 6)
                Text(formatting.resetPassedText(resetAt, kind: kind))
                    .font(.meta)
                    .foregroundStyle(.secondary)
            default:
                UsageStateMessage(state: state, kind: kind, formatting: formatting, onEnableTracking: onEnableTracking, onSignIn: onSignIn)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(formatting.accessibilityLabel(state, kind: kind))
    }
}

/// Text for states without a value, with the action that resolves them.
struct UsageStateMessage: View {
    let state: UsageWindowState
    let kind: UsageWindowKind
    let formatting: UsageFormatting
    var onEnableTracking: (() -> Void)?
    var onSignIn: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(formatting.stateText(state, kind: kind) ?? "")
                .font(.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if state == .trackingOff, let onEnableTracking {
                Button("Enable…", action: onEnableTracking).controlSize(.small)
            } else if state == .signedOut, let onSignIn {
                Button("Sign In…", action: onSignIn).controlSize(.small)
            }
        }
    }
}

/// Ring gauge for the large views. Same states and rules as the bar.
struct UsageRing: View {
    let kind: UsageWindowKind
    let state: UsageWindowState
    let formatting: UsageFormatting
    var diameter: CGFloat = 84

    var body: some View {
        HStack(spacing: Space.md) {
            ring
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(kind.title).font(.rowDetail.weight(.medium))
                Group {
                    switch state {
                    case let .fresh(window, _), let .stale(window, _):
                        Text(UsageFormatting.percent(window.usedPercentage) >= 100 ? "Limit reached" : UsageFormatting.remainingText(window))
                        Text("resets \(formatting.clockText(window.resetsAt, for: kind))")
                        Text("in \(formatting.countdown(to: window.resetsAt))")
                    case let .resetPassed(resetAt):
                        Text("Window reset at \(formatting.clockText(resetAt, for: kind))")
                        Text("no newer data")
                    default:
                        Text(formatting.stateText(state, kind: kind) ?? "")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.meta.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatting.accessibilityLabel(state, kind: kind))
    }

    private var ring: some View {
        let line: CGFloat = 8
        return ZStack {
            switch state {
            case let .fresh(window, _), let .stale(window, _):
                Circle().stroke(Color.secondary.opacity(0.16), lineWidth: line)
                Circle()
                    .trim(from: 0, to: min(max(window.usedPercentage / 100, 0), 1))
                    .stroke(usageTint(window.usedPercentage), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(state.isStale ? 0.45 : 1)
                Text(UsageFormatting.percentText(window.usedPercentage))
                    .font(.metricLarge)
                    .foregroundStyle(state.isStale ? .secondary : .primary)
            case .resetPassed:
                Circle().stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                Text("Reset").font(.rowDetail.weight(.medium)).foregroundStyle(.secondary)
            default:
                Circle().stroke(Color.secondary.opacity(0.16), lineWidth: line)
                Text("—").font(.metricLarge).foregroundStyle(.tertiary)
            }
        }
        .frame(width: diameter, height: diameter)
        .padding(line / 2)
    }
}
