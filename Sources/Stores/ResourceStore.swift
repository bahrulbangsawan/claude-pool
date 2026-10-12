import Foundation
import Observation

/// CPU and memory of the Mac and of each running claude process, sampled every few seconds.
@MainActor
@Observable
final class ResourceStore {
    static let interval: TimeInterval = 3

    struct SystemUsage: Equatable, Sendable {
        /// nil until two samples exist.
        var cpuPercent: Double?
        var memoryUsed: UInt64
        var memoryTotal: UInt64

        var memoryPercent: Double {
            memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) * 100
        }
    }

    struct ProcessUsage: Equatable, Sendable {
        /// nil until two samples exist. 100% is one full core.
        var cpuPercent: Double?
        var memory: UInt64
    }

    private(set) var system: SystemUsage?
    private(set) var processes: [Int32: ProcessUsage] = [:]

    @ObservationIgnored private var lastTicks: ResourceSampler.CPUTicks?
    @ObservationIgnored private var lastCounters: [Int32: (cpu: UInt64, at: TimeInterval)] = [:]
    @ObservationIgnored private var pidsProvider: () -> [Int32] = { [] }
    @ObservationIgnored private var timer: Timer?

    func start(pids: @escaping () -> [Int32]) {
        pidsProvider = pids
        sample()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sample(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let ticks = ResourceSampler.cpuTicks()
        let cpu = both(lastTicks, ticks).flatMap { ResourceSampler.cpuPercent(from: $0, to: $1) }
        lastTicks = ticks
        let latestSystem = ResourceSampler.memory().map { SystemUsage(cpuPercent: cpu, memoryUsed: $0.used, memoryTotal: $0.total) }
        if latestSystem != system { system = latestSystem }

        var latest: [Int32: ProcessUsage] = [:]
        var counters: [Int32: (cpu: UInt64, at: TimeInterval)] = [:]
        for pid in Set(pidsProvider()) {
            guard let now = ResourceSampler.process(pid) else { continue }
            var percent: Double?
            if let previous = lastCounters[pid], now.cpuNanoseconds >= previous.cpu {
                percent = ResourceSampler.processCPUPercent(cpuDelta: now.cpuNanoseconds - previous.cpu, wallDelta: uptime - previous.at)
            }
            latest[pid] = ProcessUsage(cpuPercent: percent, memory: now.footprint)
            counters[pid] = (now.cpuNanoseconds, uptime)
        }
        lastCounters = counters
        if latest != processes { processes = latest }
    }

    func usage(for pid: Int32) -> ProcessUsage? { processes[pid] }

    /// Sum over the given processes; CPU only when every one of them has a rate yet.
    func total(for pids: [Int32]) -> ProcessUsage? {
        let found = pids.compactMap { processes[$0] }
        guard !found.isEmpty else { return nil }
        let rates = found.compactMap(\.cpuPercent)
        return ProcessUsage(cpuPercent: rates.count == found.count ? rates.reduce(0, +) : nil,
                            memory: found.reduce(0) { $0 + $1.memory })
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
