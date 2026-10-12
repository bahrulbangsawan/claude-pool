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
        if let window = input.fiveHour { snapshot.fiveHour = Self.usageWindow(window) }
        if let window = input.sevenDay { snapshot.sevenDay = Self.usageWindow(window) }
        snapshot.lastSeenAt = now
        if input.hasAnyWindow { snapshot.observedAt = now }
        if let version = input.version { snapshot.claudeVersion = String(version.prefix(64)) }

        let data = try UsageCoding.makeEncoder().encode(snapshot)
        try AtomicFile.write(data, to: paths.snapshot(for: profileID), permissions: 0o600)

        if input.hasAnyWindow { try appendHistoryIfNeeded(input) }
    }

    private func loadSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: paths.snapshot(for: profileID)) else { return nil }
        return try? UsageCoding.makeDecoder().decode(UsageSnapshot.self, from: data)
    }

    private static func usageWindow(_ window: RateLimitInput.Window) -> UsageWindow {
        UsageWindow(usedPercentage: window.usedPercentage, resetsAt: Date(timeIntervalSince1970: window.resetsAt))
    }

    private func appendHistoryIfNeeded(_ input: RateLimitInput) throws {
        let entry = UsageHistoryEntry(
            t: now.timeIntervalSince1970.rounded(),
            fh: input.fiveHour?.usedPercentage,
            fhr: input.fiveHour?.resetsAt,
            sd: input.sevenDay?.usedPercentage,
            sdr: input.sevenDay?.resetsAt
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
