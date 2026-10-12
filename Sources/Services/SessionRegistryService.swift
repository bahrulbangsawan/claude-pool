import Darwin
import Foundation

/// One running Claude Code process, as registered by Claude Code itself in
/// `<configDir>/sessions/<pid>.json`. The profile is the config directory the file lives in, which
/// is the directory (and therefore the Keychain sign-in) that process was started with.
struct ClaudeSession: Identifiable, Hashable, Sendable {
    var id: String { "\(profileID.uuidString)-\(pid)" }
    let profileID: UUID
    let pid: Int32
    let sessionID: String
    let cwd: String
    let name: String?
    let startedAt: Date?
    let updatedAt: Date?
    /// Claude Code's own status, e.g. `busy` or `idle`.
    let status: String?
    let version: String?
    let kind: String?

    var isBusy: Bool { status == "busy" }

    /// Last path component of the working directory, for compact rows.
    var folderName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

/// Reads Claude Code's per-process session registry. Read-only; never writes to a profile.
///
/// Compliance: only the keys in `Entry` are decoded; the registry also holds a messaging socket
/// path and peer data, which are never declared, read or stored.
struct SessionRegistryService: Sendable {
    /// Process start time lookup, injectable for tests.
    var processStartTime: @Sendable (Int32) -> Date? = SessionRegistryService.liveStartTime

    static func directory(for profile: Profile) -> URL {
        profile.configURL.appendingPathComponent("sessions", isDirectory: true)
    }

    private struct Entry: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String?
        let startedAt: Double?
        let updatedAt: Double?
        let status: String?
        let version: String?
        let kind: String?
        let procStart: String?
    }

    /// Live sessions of all profiles, newest first.
    func sessions(for profiles: [Profile]) -> [ClaudeSession] {
        profiles.flatMap(sessions(for:)).sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func sessions(for profile: Profile) -> [ClaudeSession] {
        let directory = Self.directory(for: profile)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [ClaudeSession] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let pid = Int32(name.dropLast(5)), pid > 0,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  data.count < 256 * 1024,
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.pid == pid,
                  isAlive(entry) else { continue }
            result.append(ClaudeSession(
                profileID: profile.id,
                pid: pid,
                sessionID: String(entry.sessionId.prefix(64)),
                cwd: entry.cwd,
                name: entry.name.map { String($0.prefix(80)) },
                startedAt: entry.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                updatedAt: entry.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                status: entry.status.map { String($0.prefix(24)) },
                version: entry.version.map { String($0.prefix(32)) },
                kind: entry.kind.map { String($0.prefix(24)) }
            ))
        }
        return result
    }

    /// The pid exists and is the same process Claude Code registered (not a reused pid).
    private func isAlive(_ entry: Entry) -> Bool {
        guard let started = processStartTime(entry.pid) else { return false }
        if let procStart = entry.procStart, let registered = Self.parseProcStart(procStart) {
            return abs(started.timeIntervalSince(registered)) <= 2
        }
        // Older registries without procStart: the process must predate the session.
        if let sessionStart = entry.startedAt.map({ Date(timeIntervalSince1970: $0 / 1000) }) {
            return started <= sessionStart.addingTimeInterval(2)
        }
        return true
    }

    /// `ps -o lstart` style, in UTC: "Mon Oct 12 04:33:38 2026" (day may be space-padded).
    static func parseProcStart(_ text: String) -> Date? {
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: collapsed)
    }

    /// Start time of a live process owned by anyone (kern.proc.pid), or nil when it does not exist.
    @Sendable static func liveStartTime(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        // Zombies have exited.
        if info.kp_proc.p_stat == SZOMB { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
