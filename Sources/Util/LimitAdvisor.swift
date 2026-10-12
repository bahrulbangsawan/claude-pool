import Foundation

/// Decides when a reported usage window deserves a notification: once when it first reaches the
/// alert threshold and once when it reaches 100%, per reset period. Only fresh values count, and
/// nothing is estimated. The first update after launch records the current levels silently.
struct LimitAlertTracker {
    enum Level: Int, Comparable, Sendable {
        case below, near, reached
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Observation: Sendable {
        let profileID: UUID
        let kind: UsageWindowKind
        let state: UsageWindowState
    }

    struct Event: Equatable, Sendable {
        let profileID: UUID
        let kind: UsageWindowKind
        let level: Level
        let percent: Int
        let resetsAt: Date
    }

    private struct Key: Hashable {
        let profileID: UUID
        let kind: UsageWindowKind
    }

    /// Reset times within this distance belong to the same window period.
    static let samePeriodTolerance: TimeInterval = 120

    private var seen: [Key: (resetsAt: Date, level: Level)] = [:]
    private(set) var isPrimed = false

    static func level(percent: Int, threshold: Int) -> Level {
        if percent >= 100 { return .reached }
        if percent >= threshold { return .near }
        return .below
    }

    mutating func update(_ observations: [Observation], threshold: Int) -> [Event] {
        var events: [Event] = []
        for observation in observations {
            guard case let .fresh(window, _) = observation.state else { continue }
            let key = Key(profileID: observation.profileID, kind: observation.kind)
            let percent = UsageFormatting.percent(window.usedPercentage)
            let level = Self.level(percent: percent, threshold: threshold)
            let previous = seen[key]
            let samePeriod = previous.map { abs($0.resetsAt.timeIntervalSince(window.resetsAt)) < Self.samePeriodTolerance } ?? false
            let baseline = samePeriod ? previous!.level : .below
            if level > baseline, isPrimed {
                events.append(Event(profileID: observation.profileID, kind: observation.kind, level: level, percent: percent, resetsAt: window.resetsAt))
            }
            seen[key] = (window.resetsAt, max(level, baseline))
        }
        isPrimed = true
        return events
    }

    mutating func forget(_ profileID: UUID) {
        seen = seen.filter { $0.key.profileID != profileID }
    }
}

/// Points at the signed-in account with the most room left when the active one is close to or at
/// a limit. It only ever informs: switching stays a click by the user.
enum AccountAdvisor {
    struct Candidate: Sendable {
        let profileID: UUID
        let fiveHour: UsageWindowState
        let sevenDay: UsageWindowState
        let signedIn: Bool?

        var availability: AccountAvailability {
            AccountAvailability.evaluate(fiveHour: fiveHour, sevenDay: sevenDay, signedIn: signedIn)
        }

        /// The highest reported share: the window that runs out first. nil without any value.
        var load: Int? {
            [fiveHour, sevenDay].compactMap(\.displayedWindow).map { UsageFormatting.percent($0.usedPercentage) }.max()
        }

        var isStale: Bool { fiveHour.isStale || sevenDay.isStale }
    }

    /// Whether the active account is at a limit or at/above the alert threshold.
    static func needsAlternative(_ active: Candidate, threshold: Int) -> Bool {
        if case .limited = active.availability { return true }
        return (active.load ?? 0) >= threshold
    }

    /// The other account with the lowest load below the threshold; fresh values before stale ones,
    /// then the user's order. nil when the active account is fine or no account qualifies.
    static func suggest(active: Candidate?, others: [Candidate], threshold: Int) -> Candidate? {
        guard let active, needsAlternative(active, threshold: threshold) else { return nil }
        let eligible = others.enumerated().filter { _, candidate in
            guard candidate.profileID != active.profileID, case .available = candidate.availability,
                  let load = candidate.load else { return false }
            return load < threshold
        }
        return eligible.min { a, b in
            let lhs = (a.element.isStale ? 1 : 0, a.element.load ?? 100, a.offset)
            let rhs = (b.element.isStale ? 1 : 0, b.element.load ?? 100, b.offset)
            return lhs < rhs
        }?.element
    }
}

/// Compact text for the menu bar label.
enum MenuBarText {
    /// "5h:23% · 7d:41%", with "–" for a window without a value. nil when neither has one.
    static func usage(fiveHour: UsageWindow?, sevenDay: UsageWindow?) -> String? {
        guard fiveHour != nil || sevenDay != nil else { return nil }
        func part(_ kind: UsageWindowKind, _ window: UsageWindow?) -> String {
            "\(kind.shortLabel):\(window.map { UsageFormatting.percentText($0.usedPercentage) } ?? "–")"
        }
        return "\(part(.fiveHour, fiveHour)) · \(part(.sevenDay, sevenDay))"
    }

    /// "CPU 12% · MEM 64%", with "–" for CPU until two samples exist.
    static func system(_ usage: ResourceStore.SystemUsage?) -> String? {
        guard let usage else { return nil }
        let cpu = usage.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "–"
        return "CPU \(cpu) · MEM \(Int(usage.memoryPercent.rounded()))%"
    }

    /// "1.2 GB", "412 MB".
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    /// "12%"; one decimal below 10% so idle processes don't all read 0%.
    static func cpu(_ percent: Double?) -> String {
        guard let percent else { return "–" }
        return percent < 10 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }
}
