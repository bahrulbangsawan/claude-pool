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

        var snapshot = loadSnapshot() ?? UsageSnapshot(profileId: profileID, lastSeenAt: now)
        snapshot.schema = UsageSnapshot.currentSchema
        snapshot.profileId = profileID
        let fiveHour = input.fiveHour.flatMap { Self.fresh($0, over: snapshot.fiveHour, now: now) }
        let sevenDay = input.sevenDay.flatMap { Self.fresh($0, over: snapshot.sevenDay, now: now) }
        if let fiveHour { snapshot.fiveHour = Self.usageWindow(fiveHour) }
        if let sevenDay { snapshot.sevenDay = Self.usageWindow(sevenDay) }
        snapshot.lastSeenAt = now
        if fiveHour != nil || sevenDay != nil { snapshot.observedAt = now }
        if let version = input.version { snapshot.claudeVersion = String(version.prefix(64)) }

        let data = try UsageCoding.makeEncoder().encode(snapshot)
        try AtomicFile.write(data, to: paths.snapshot(for: profileID), permissions: 0o600)

        if fiveHour != nil || sevenDay != nil { try appendHistoryIfNeeded(fiveHour: fiveHour, sevenDay: sevenDay) }
    }

    /// Reset times closer than this are treated as the same window.
    static let sameWindowTolerance: TimeInterval = 60

    /// Returns `incoming` unless it is a stale report of the stored window.
    ///
    /// Every session sharing a config directory runs the collector, and an idle session keeps
    /// re-reporting the rate limits from its last API response. Within one window usage never
    /// goes down, so a lower value for the same reset time is an old report and is dropped.
    static func fresh(_ incoming: RateLimitInput.Window, over stored: UsageWindow?, now: Date) -> RateLimitInput.Window? {
        guard let stored else { return incoming }
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

    private func appendHistoryIfNeeded(fiveHour: RateLimitInput.Window?, sevenDay: RateLimitInput.Window?) throws {
        let entry = UsageHistoryEntry(
            t: now.timeIntervalSince1970.rounded(),
            fh: fiveHour?.usedPercentage,
            fhr: fiveHour?.resetsAt,
            sd: sevenDay?.usedPercentage,
            sdr: sevenDay?.resetsAt
        )
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
