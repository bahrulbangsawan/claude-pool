import Foundation
import Observation

/// Latest usage snapshots written by the collector, plus history for charts.
/// Watches ~/.claude-pool/usage with a DispatchSource and ticks every 30s for relative times.
@MainActor
@Observable
final class UsageStore {
    static let historyMaxAge: TimeInterval = 8 * 24 * 60 * 60
    static let historyMaxLines = 5_000

    private(set) var snapshots: [UUID: UsageSnapshot] = [:]
    /// Advances every 30 seconds so "observed 3m ago" and countdowns stay current.
    private(set) var now = Date()
    var lastError: String?

    let pool: PoolPaths
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingReload = false
    /// Called after the collector wrote something, i.e. Claude Code just rendered a status line.
    @ObservationIgnored var onActivity: (() -> Void)?

    init(pool: PoolPaths) {
        self.pool = pool
    }

    func snapshot(for id: UUID) -> UsageSnapshot? { snapshots[id] }

    // MARK: Watching

    func start() {
        reload()
        startWatching()
        timer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
        if source == nil { startWatching() }
    }

    private func startWatching() {
        guard source == nil else { return }
        try? AtomicFile.ensureDirectory(pool.home, permissions: 0o700)
        try? AtomicFile.ensureDirectory(pool.usageDirectory, permissions: 0o700)
        let fd = open(pool.usageDirectory.path, O_EVTONLY)
        guard fd >= 0 else {
            lastError = "Could not watch \(pool.usageDirectory.path); usage refreshes every 30 seconds instead."
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Coalesces bursts of directory events (temp file + rename) into one read.
    private func scheduleReload() {
        guard !pendingReload else { return }
        pendingReload = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.pendingReload = false
            self?.reload()
            self?.onActivity?()
        }
    }

    // MARK: Reading

    func reload() {
        now = Date()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: pool.usageDirectory.path) else {
            snapshots = [:]
            return
        }
        let decoder = UsageCoding.makeDecoder()
        var loaded: [UUID: UsageSnapshot] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let id = UUID(uuidString: String(name.dropLast(5))),
                  let data = try? Data(contentsOf: pool.snapshot(for: id)),
                  let snapshot = try? decoder.decode(UsageSnapshot.self, from: data),
                  snapshot.profileId == id else { continue }
            loaded[id] = snapshot
        }
        if loaded != snapshots { snapshots = loaded }
    }

    /// History entries newer than `since`, oldest first.
    func history(for id: UUID, since: Date) -> [UsageHistoryEntry] {
        Self.readHistory(at: pool.history(for: id)).filter { $0.date >= since }
    }

    nonisolated static func readHistory(at url: URL) -> [UsageHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(UsageHistoryEntry.self, from: Data($0))
        }
    }

    // MARK: Maintenance

    /// Keeps the last 8 days and at most 5,000 lines per history file.
    func pruneHistory(now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: pool.usageDirectory.path) else { return }
        let encoder = UsageCoding.makeEncoder()
        for name in names where name.hasSuffix(".history.jsonl") {
            let url = pool.usageDirectory.appendingPathComponent(name)
            let entries = Self.readHistory(at: url)
            let kept = Array(entries.filter { now.timeIntervalSince($0.date) <= Self.historyMaxAge }.suffix(Self.historyMaxLines))
            guard kept.count != entries.count else { continue }
            var data = Data()
            for entry in kept {
                guard let line = try? encoder.encode(entry) else { continue }
                data.append(line)
                data.append(UInt8(ascii: "\n"))
            }
            do {
                try AtomicFile.write(data, to: url, permissions: 0o600)
            } catch {
                lastError = "Could not prune usage history: \(error.localizedDescription)"
            }
        }
    }

    /// Removes the app's own usage files for a deleted profile.
    func removeData(for id: UUID) {
        try? FileManager.default.removeItem(at: pool.snapshot(for: id))
        try? FileManager.default.removeItem(at: pool.history(for: id))
        snapshots[id] = nil
    }
}
