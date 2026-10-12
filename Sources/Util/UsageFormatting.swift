import Foundation

/// What a single usage window should display. Computed in the spec's priority order.
enum UsageWindowState: Equatable, Sendable {
    case trackingOff
    case signedOut
    case notReported
    case noData
    case resetPassed(resetAt: Date)
    case stale(UsageWindow, observedAt: Date)
    case fresh(UsageWindow, observedAt: Date)

    /// The reported window when there is a value to show (Fresh or Stale only).
    var displayedWindow: UsageWindow? {
        switch self {
        case let .fresh(window, _), let .stale(window, _): window
        default: nil
        }
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

enum UsageBarLevel: Equatable, Sendable {
    case normal    // < 70%
    case elevated  // 70–89%
    case critical  // ≥ 90%
}

/// Turns reported values into display text. Never estimates, interpolates or extrapolates.
struct UsageFormatting {
    static let staleAfter: TimeInterval = 15 * 60
    static let staleFootnote = "Usage from claude.ai or other devices after this time is not included."
    static let noDataText = "No data yet — start a claude session with this profile and send one message"
    static let notReportedText = "Not reported for this sign-in or plan"
    static let trackingOffText = "Usage tracking off"
    static let signedOutText = "Signed out"

    var now: Date
    var locale: Locale = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent

    // MARK: State

    static func state(
        for kind: UsageWindowKind,
        trackingEnabled: Bool,
        auth: AuthStatus?,
        snapshot: UsageSnapshot?,
        now: Date
    ) -> UsageWindowState {
        if !trackingEnabled { return .trackingOff }
        if let auth, !auth.signedIn { return .signedOut }
        if let auth, !auth.reportsUsage { return .notReported }
        if let snapshot, snapshot.observedAt == nil { return .notReported }
        guard let snapshot, let observedAt = snapshot.observedAt, let window = snapshot.window(kind) else {
            return .noData
        }
        if now >= window.resetsAt { return .resetPassed(resetAt: window.resetsAt) }
        if now.timeIntervalSince(observedAt) > staleAfter { return .stale(window, observedAt: observedAt) }
        return .fresh(window, observedAt: observedAt)
    }

    // MARK: Values

    static func percent(_ value: Double) -> Int { Int(value.rounded()) }

    static func percentText(_ value: Double) -> String { "\(percent(value))%" }

    static func level(for value: Double) -> UsageBarLevel {
        let p = percent(value)
        if p >= 90 { return .critical }
        if p >= 70 { return .elevated }
        return .normal
    }

    // MARK: Times

    /// "14:05" for the 5-hour window, "Thu 09:00" for the 7-day window (locale-aware).
    func clockText(_ date: Date, for kind: UsageWindowKind) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(kind == .fiveHour ? "jjmm" : "EEEjjmm")
        return formatter.string(from: date)
    }

    /// "2h 13m", "3d 4h", "45m", "<1m". Counts down to a reported reset time.
    func countdown(to date: Date) -> String {
        let seconds = Int(max(0, date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// "resets 14:05 · in 2h 13m" / "resets Thu 09:00 · in 3d 4h"
    func resetText(_ window: UsageWindow, kind: UsageWindowKind) -> String {
        "resets \(clockText(window.resetsAt, for: kind)) · in \(countdown(to: window.resetsAt))"
    }

    func resetPassedText(_ resetAt: Date, kind: UsageWindowKind) -> String {
        "Window reset at \(clockText(resetAt, for: kind)) · no newer data"
    }

    /// "just now", "4m ago", "2h 5m ago", "3d ago".
    func age(since date: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 {
            let minutes = (seconds % 3_600) / 60
            return minutes == 0 ? "\(seconds / 3_600)h ago" : "\(seconds / 3_600)h \(minutes)m ago"
        }
        return "\(seconds / 86_400)d ago"
    }

    /// "observed 3m ago" when fresh, "as of 25m ago" when stale.
    func observationText(_ state: UsageWindowState) -> String? {
        switch state {
        case let .fresh(_, observedAt): "observed \(age(since: observedAt))"
        case let .stale(_, observedAt): "as of \(age(since: observedAt))"
        default: nil
        }
    }

    /// Single-line text for states without a value.
    func stateText(_ state: UsageWindowState, kind: UsageWindowKind) -> String? {
        switch state {
        case .trackingOff: Self.trackingOffText
        case .signedOut: Self.signedOutText
        case .notReported: Self.notReportedText
        case .noData: Self.noDataText
        case let .resetPassed(resetAt): resetPassedText(resetAt, kind: kind)
        case .fresh, .stale: nil
        }
    }

    /// VoiceOver: "5-hour limit 23 percent, resets at 14:05".
    func accessibilityLabel(_ state: UsageWindowState, kind: UsageWindowKind) -> String {
        switch state {
        case let .fresh(window, observedAt), let .stale(window, observedAt):
            let base = "\(kind.spokenLabel) \(Self.percent(window.usedPercentage)) percent, resets at \(clockText(window.resetsAt, for: kind))"
            return state.isStale ? "\(base), as of \(age(since: observedAt))" : base
        default:
            return "\(kind.spokenLabel): \(stateText(state, kind: kind) ?? "")"
        }
    }
}

/// Whether an account can be used right now, from the reported windows only.
enum AccountAvailability: Equatable, Sendable {
    case signedOut
    /// No window value to judge from (tracking off, no data yet, not reported).
    case unknown
    /// Every reported window is below 100%. `nearLimit` when one is at 90% or more.
    case available(nearLimit: Bool, stale: Bool)
    /// A reported window is at 100%: blocked until its reset (the latest such reset).
    case limited(until: Date, kind: UsageWindowKind, stale: Bool)

    static func evaluate(fiveHour: UsageWindowState, sevenDay: UsageWindowState, signedIn: Bool?) -> AccountAvailability {
        if signedIn == false { return .signedOut }
        var limited: (Date, UsageWindowKind, Bool)?
        var near = false
        var any = false
        var stale = false
        for (kind, state) in [(UsageWindowKind.fiveHour, fiveHour), (.sevenDay, sevenDay)] {
            guard let window = state.displayedWindow else { continue }
            any = true
            stale = stale || state.isStale
            let percent = UsageFormatting.percent(window.usedPercentage)
            if percent >= 100 {
                if limited == nil || window.resetsAt > limited!.0 { limited = (window.resetsAt, kind, state.isStale) }
            } else if percent >= 90 {
                near = true
            }
        }
        if let limited { return .limited(until: limited.0, kind: limited.1, stale: limited.2) }
        return any ? .available(nearLimit: near, stale: stale) : .unknown
    }
}

extension UsageFormatting {
    /// "77% left" — the remaining share of a reported window. Percent only: absolute allowances
    /// are not reported by Claude Code.
    static func remainingText(_ window: UsageWindow) -> String {
        "\(max(0, 100 - percent(window.usedPercentage)))% left"
    }

    /// Plain-language availability for cards and menus.
    func availabilityText(_ availability: AccountAvailability) -> String {
        switch availability {
        case .signedOut: "Signed out"
        case .unknown: "Availability unknown — no usage reported yet"
        case let .available(near, stale): (near ? "Usable · close to a limit" : "Usable") + (stale ? " (as last reported)" : "")
        case let .limited(until, kind, stale):
            "\(kind == .fiveHour ? "5-hour" : "7-day") limit reached · resets \(clockText(until, for: kind)) (in \(countdown(to: until)))" + (stale ? " · as last reported" : "")
        }
    }
}
