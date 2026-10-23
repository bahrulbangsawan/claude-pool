import Foundation
import PoolShared

/// Merges one status line payload into the profile's snapshot and history files.
struct SnapshotWriter {
    static let historyInterval: TimeInterval = 5 * 60

    let paths: PoolPaths
    let profileID: UUID
    let now: Date

    func apply(_ input: RateLimitInput) throws {
        try AtomicFile.ensureDirectory(paths.home)
        try AtomicFile.ensureDirectory(paths.usageDirectory)

        let stored = loadSnapshot()
        var snapshot = stored ?? UsageSnapshot(profileId: profileID, lastSeenAt: now)
        snapshot.schema = UsageSnapshot.currentSchema
        snapshot.profileId = profileID
        let current = try currentWindows(input, stored: stored)
        if let window = current.fiveHour { snapshot.fiveHour = Self.usageWindow(window) }
        if let window = current.sevenDay { snapshot.sevenDay = Self.usageWindow(window) }
        snapshot.lastSeenAt = now
        if current.observed { snapshot.observedAt = now }
        if let version = input.version { snapshot.claudeVersion = String(version.prefix(64)) }

        let data = try UsageCoding.makeEncoder().encode(snapshot)
        try AtomicFile.write(data, to: paths.snapshot(for: profileID), permissions: 0o600)

        if current.observed { try appendHistoryIfNeeded(Self.historyEntry(snapshot, input: input, now: now)) }
    }

    /// The windows to store, and whether this report is a current observation. With a session key
    /// the choice comes from `ReporterLog`; without one (older Claude Code), from `fresh`.
    private func currentWindows(_ input: RateLimitInput, stored: UsageSnapshot?) throws
        -> (fiveHour: RateLimitInput.Window?, sevenDay: RateLimitInput.Window?, observed: Bool) {
        guard input.hasAnyWindow else { return (nil, nil, false) }
        if let key = input.sessionKey {
            let url = paths.reporters(for: profileID)
            var log = ReporterLog.load(url) ?? ReporterLog(since: now.timeIntervalSince1970)
            let choice = log.record(key: key, fiveHour: input.fiveHour, sevenDay: input.sevenDay, now: now)
            try log.save(to: url)
            return (choice.fiveHour, choice.sevenDay, choice.fromThisReport)
        }
        let afterGap = stored.map { now.timeIntervalSince($0.lastSeenAt) > Self.sessionGap } ?? true
        let fiveHour = input.fiveHour.flatMap { Self.fresh($0, over: stored?.fiveHour, now: now, afterGap: afterGap) }
        let sevenDay = input.sevenDay.flatMap { Self.fresh($0, over: stored?.sevenDay, now: now, afterGap: afterGap) }
        return (fiveHour, sevenDay, fiveHour != nil || sevenDay != nil)
    }

    /// Both current windows after the merge, so reports from several sessions can't make
    /// consecutive entries differ. A stored window that has reset is left out unless this report
    /// carries that window (Claude Code stops sending a window once it resets).
    static func historyEntry(_ snapshot: UsageSnapshot, input: RateLimitInput, now: Date) -> UsageHistoryEntry {
        func current(_ window: UsageWindow?, reported: Bool) -> UsageWindow? {
            guard let window, reported || window.resetsAt > now else { return nil }
            return window
        }
        let fiveHour = current(snapshot.fiveHour, reported: input.fiveHour != nil)
        let sevenDay = current(snapshot.sevenDay, reported: input.sevenDay != nil)
        return UsageHistoryEntry(
            t: now.timeIntervalSince1970.rounded(),
            fh: fiveHour?.usedPercentage,
            fhr: fiveHour?.resetsAt.timeIntervalSince1970,
            sd: sevenDay?.usedPercentage,
            sdr: sevenDay?.resetsAt.timeIntervalSince1970
        )
    }

    /// Reset times closer than this are treated as the same window.
    static let sameWindowTolerance: TimeInterval = 60

    /// With no collector run for this long, no session that reported before is assumed to be open.
    static let sessionGap: TimeInterval = 120

    /// Returns `incoming` unless it is a stale report of the stored window.
    ///
    /// Every session sharing a config directory runs the collector, and an idle session keeps
    /// re-reporting the rate limits from its last API response. While sessions keep reporting, a
    /// lower value for the same reset time is treated as such an old report and dropped.
    /// After a gap the value is taken as is: Claude Code sends `rate_limits` only after a session's
    /// first API response, so a session started since reports current usage, and the server can
    /// lower a window's usage (seen live: 100% → 77% with the same reset).
    static func fresh(_ incoming: RateLimitInput.Window, over stored: UsageWindow?, now: Date, afterGap: Bool = false) -> RateLimitInput.Window? {
        guard let stored, !afterGap else { return incoming }
        let storedReset = stored.resetsAt.timeIntervalSince1970
        if storedReset <= now.timeIntervalSince1970 { return incoming }
        if abs(incoming.resetsAt - storedReset) < sameWindowTolerance {
            return incoming.usedPercentage >= stored.usedPercentage ? incoming : nil
        }
        // A later reset is a newer window; an earlier one is from a window that has already ended.
        return incoming.resetsAt > storedReset ? incoming : nil
    }

    private func loadSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: paths.snapshot(for: profileID)) else { return nil }
        return try? UsageCoding.makeDecoder().decode(UsageSnapshot.self, from: data)
    }

    private static func usageWindow(_ window: RateLimitInput.Window) -> UsageWindow {
        UsageWindow(usedPercentage: window.usedPercentage, resetsAt: Date(timeIntervalSince1970: window.resetsAt))
    }

    private func appendHistoryIfNeeded(_ entry: UsageHistoryEntry) throws {
        guard entry.fh != nil || entry.sd != nil else { return }
        let url = paths.history(for: profileID)
        if let last = Self.lastEntry(in: url),
           last.hasSameValues(as: entry),
           entry.t - last.t < Self.historyInterval {
            return
        }

        var line = try UsageCoding.makeEncoder().encode(entry)
        line.append(UInt8(ascii: "\n"))
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFileError.write(path: url.path, errno: errno) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        // A single small write with O_APPEND lands as one line even with concurrent writers.
        let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        if written != line.count { throw AtomicFileError.write(path: url.path, errno: errno) }
    }

    /// Reads only the tail of the history file to find the last entry.
    static func lastEntry(in url: URL) -> UsageHistoryEntry? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let tail: UInt64 = min(size, 4096)
        try? handle.seek(toOffset: size - tail)
        guard let data = try? handle.readToEnd() else { return nil }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            if let entry = try? JSONDecoder().decode(UsageHistoryEntry.self, from: Data(line)) {
                return entry
            }
        }
        return nil
    }
}
