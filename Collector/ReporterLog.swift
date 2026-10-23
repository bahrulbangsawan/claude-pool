import Foundation
import PoolShared

/// What each open claude session last reported for one profile, so the collector can tell a current
/// value from an idle session re-sending the rate limits of its last API response.
///
/// Sessions are told apart by `RateLimitInput.sessionKey`, a hash; the session ID is never stored.
/// Per window, the value that counts is the one from the session whose report for that window
/// changed most recently. A session only reports after its first API response, so its first report
/// counts as a change; an idle session repeats itself unchanged. This lets usage go down when the
/// server lowers it, which a "highest value wins" rule cannot.
struct ReporterLog: Codable {
    struct Reporter: Codable {
        var k: String
        var fh: Double?
        var fhr: Double?
        /// When this session's 5-hour report last changed.
        var fc: Double?
        var sd: Double?
        var sdr: Double?
        var sc: Double?
        /// Last report of any kind.
        var s: Double
    }

    struct Choice {
        var fiveHour: RateLimitInput.Window?
        var sevenDay: RateLimitInput.Window?
        /// Whether this report supplied one of the chosen windows, i.e. it is a current observation.
        var fromThisReport: Bool
    }

    /// Right after the log is created every open session is new to it, idle ones included. Sessions
    /// first seen in this period rank by value only, like the old "highest value wins" rule.
    static let warmUp: TimeInterval = 30
    static let maxAge: TimeInterval = 8 * 24 * 60 * 60
    static let maxReporters = 64

    var schema = 1
    var since: Double
    var reporters: [Reporter] = []

    static func load(_ url: URL) -> ReporterLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReporterLog.self, from: data)
    }

    func save(to url: URL) throws {
        try AtomicFile.write(try UsageCoding.makeEncoder().encode(self), to: url, permissions: 0o600)
    }

    mutating func record(key: String, fiveHour: RateLimitInput.Window?, sevenDay: RateLimitInput.Window?, now: Date) -> Choice {
        let t = now.timeIntervalSince1970
        reporters.removeAll { t - $0.s > Self.maxAge }
        let firstSeen = t - since < Self.warmUp ? 0 : t
        var reporter = reporters.first { $0.k == key } ?? Reporter(k: key, s: t)
        if let window = fiveHour {
            if reporter.fh != window.usedPercentage || !Self.sameReset(reporter.fhr, window.resetsAt) {
                reporter.fc = reporter.fh == nil ? firstSeen : t
            }
            reporter.fh = window.usedPercentage
            reporter.fhr = window.resetsAt
        }
        if let window = sevenDay {
            if reporter.sd != window.usedPercentage || !Self.sameReset(reporter.sdr, window.resetsAt) {
                reporter.sc = reporter.sd == nil ? firstSeen : t
            }
            reporter.sd = window.usedPercentage
            reporter.sdr = window.resetsAt
        }
        reporter.s = t
        reporters.removeAll { $0.k == key }
        reporters.append(reporter)
        if reporters.count > Self.maxReporters {
            reporters = Array(reporters.sorted { $0.s > $1.s }.prefix(Self.maxReporters))
        }

        let five = Self.choose(reporters.compactMap { r in r.fh.flatMap { v in r.fhr.map { (v, $0, r.fc ?? 0, r.k) } } })
        let seven = Self.choose(reporters.compactMap { r in r.sd.flatMap { v in r.sdr.map { (v, $0, r.sc ?? 0, r.k) } } })
        let fromThisReport = (fiveHour != nil && five?.key == key) || (sevenDay != nil && seven?.key == key)
        return Choice(fiveHour: five?.window, sevenDay: seven?.window, fromThisReport: fromThisReport)
    }

    /// The newest window (latest reset), and within it the report that changed most recently.
    private static func choose(_ reports: [(value: Double, reset: Double, changed: Double, key: String)]) -> (window: RateLimitInput.Window, key: String)? {
        guard let newest = reports.map(\.reset).max() else { return nil }
        let best = reports
            .filter { newest - $0.reset < SnapshotWriter.sameWindowTolerance }
            .max { ($0.changed, $0.value) < ($1.changed, $1.value) }
        return best.map { (RateLimitInput.Window(usedPercentage: $0.value, resetsAt: $0.reset), $0.key) }
    }

    private static func sameReset(_ stored: Double?, _ incoming: Double) -> Bool {
        stored.map { abs($0 - incoming) < SnapshotWriter.sameWindowTolerance } ?? false
    }
}
