import Foundation
import Observation

enum AnalyticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    /// Chart granularity: hourly for a day, 6-hourly for a week, daily for a month.
    var bucket: AnalyticsBucket {
        switch self {
        case .day: .hour
        case .week: .sixHours
        case .month: .day
        }
    }
}

enum AnalyticsBucket: Sendable {
    case hour, sixHours, day

    /// Start of the local-time bucket containing `date`. Uses the calendar, so DST and
    /// non-whole-hour time zones are handled.
    func start(of date: Date, calendar: Calendar) -> Date {
        switch self {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .sixHours:
            let hour = calendar.component(.hour, from: date)
            let day = calendar.startOfDay(for: date)
            return calendar.date(byAdding: .hour, value: hour - hour % 6, to: day) ?? day
        case .day:
            return calendar.startOfDay(for: date)
        }
    }

    func next(after start: Date, calendar: Calendar) -> Date {
        switch self {
        case .hour: calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)
        case .sixHours: calendar.date(byAdding: .hour, value: 6, to: start) ?? start.addingTimeInterval(21_600)
        case .day: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        }
    }
}

/// Everything the analytics page draws for one period and filter.
struct AnalyticsReport: Sendable, Equatable {
    struct Point: Sendable, Equatable, Identifiable {
        var id: Date { start }
        var start: Date
        var end: Date
        var totals: TokenTotals
    }

    struct Share: Sendable, Equatable, Identifiable {
        var id: String
        var label: String
        var totals: TokenTotals
    }

    var period: AnalyticsPeriod
    var start: Date
    var end: Date
    var current: TokenTotals
    var previous: TokenTotals
    var series: [Point]
    var byProfile: [Share]
    var byModel: [Share]
    /// Earliest request in the index; comparisons before it are incomplete.
    var coverageStart: Date?

    /// Percent change vs the previous equal-length period; nil when there's nothing to compare with.
    static func change(_ current: Int64, _ previous: Int64) -> Double? {
        guard previous > 0 else { return nil }
        return (Double(current) - Double(previous)) / Double(previous) * 100
    }

    /// True when the previous period lies (partly) before the oldest indexed request.
    var previousIsPartial: Bool {
        guard let coverageStart else { return true }
        return coverageStart > start.addingTimeInterval(-period.duration)
    }
}

/// Recorded token usage across profiles, from the persistent `UsageIndex`.
@MainActor
@Observable
final class AnalyticsStore {
    enum Status: Equatable {
        case idle
        case indexing(done: Int, total: Int)
        case failed(String)
    }

    var period: AnalyticsPeriod = .week { didSet { if period != oldValue { reloadReport() } } }
    /// nil = all profiles.
    var profileFilter: UUID? { didSet { if profileFilter != oldValue { reloadReport() } } }
    /// nil = all models.
    var modelFilter: String? { didSet { if modelFilter != oldValue { reloadReport() } } }

    private(set) var report: AnalyticsReport?
    private(set) var status: Status = .idle
    private(set) var lastIndexedAt: Date?
    private(set) var indexedFiles = 0
    private(set) var availableModels: [String] = []

    @ObservationIgnored private var index: UsageIndex?
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private var profilesProvider: () -> [Profile] = { [] }
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var calendar = Calendar.autoupdatingCurrent
    @ObservationIgnored var clock: () -> Date = Date.init

    init(indexURL: URL) {
        self.indexURL = indexURL
    }

    func start(profiles: @escaping () -> [Profile]) {
        profilesProvider = profiles
        do {
            index = try UsageIndex(url: indexURL)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        reloadReport()
        rescan()
        timer?.invalidate()
        // A safety net; new activity normally triggers a scan within seconds (see `noteActivity`).
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called when Claude Code shows signs of activity (status line runs, session changes).
    func noteActivity() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    /// Incremental scan of every profile's conversation files; coalesces concurrent requests.
    func rescan() {
        guard let index else { return }
        if scanTask != nil { rescanRequested = true; return }
        let profiles = profilesProvider().map { (id: $0.id, projects: $0.configURL.appendingPathComponent("projects", isDirectory: true)) }
        let now = clock()
        scanTask = Task { [weak self] in
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { @MainActor in
                    guard let self, total > 0, done < total else { return }
                    // Only show progress for the initial or a large scan.
                    if total - done > 20 || self.isIndexing { self.status = .indexing(done: done, total: total) }
                }
            }
            do {
                _ = try await index.scan(profiles: profiles, now: now, progress: progress)
                let files = try await index.indexedFileCount()
                await MainActor.run {
                    guard let self else { return }
                    self.indexedFiles = files
                    self.lastIndexedAt = now
                    self.status = .idle
                }
            } catch {
                await MainActor.run { self?.status = .failed(error.localizedDescription) }
            }
            await MainActor.run {
                guard let self else { return }
                self.scanTask = nil
                self.reloadReport()
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.rescan()
                }
            }
        }
    }

    private var isIndexing: Bool {
        if case .indexing = status { return true }
        return false
    }

    /// Records conversation files copied by a handoff as already counted.
    func registerCopiedFiles(_ files: [(url: URL, size: Int64)], profileID: UUID) async {
        guard let index else { return }
        try? await index.markIndexed(files, profileID: profileID)
    }

    func removeProfile(_ id: UUID) {
        guard let index else { return }
        Task {
            try? await index.removeProfile(id)
            reloadReport()
        }
    }

    // MARK: Report

    func reloadReport() {
        guard let index else { return }
        let period = period
        let end = clock()
        let start = end.addingTimeInterval(-period.duration)
        let previousStart = start.addingTimeInterval(-period.duration)
        let profileFilter = profileFilter
        let modelFilter = modelFilter
        let names = Dictionary(uniqueKeysWithValues: profilesProvider().map { ($0.id, $0.name) })
        let calendar = calendar
        Task {
            do {
                let slots = try await index.slots(from: previousStart, to: end)
                let coverage = try await index.oldestRequest()
                var report = Self.makeReport(slots: slots, period: period, start: start, end: end, profileFilter: profileFilter,
                                             modelFilter: modelFilter, names: names, calendar: calendar, coverageStart: coverage)
                // Summary cards use exact per-request totals; the chart uses 15-minute slots.
                let profileSet = profileFilter.map { Set([$0]) }
                let modelSet = modelFilter.map { Set([$0]) }
                report.current = try await index.totals(from: start, to: end, profiles: profileSet, models: modelSet)
                report.previous = try await index.totals(from: previousStart, to: start, profiles: profileSet, models: modelSet)
                let models = Array(Set(slots.filter { $0.slotStart >= start }.map(\.model))).sorted()
                if self.report != report { self.report = report }
                if self.availableModels != models { self.availableModels = models }
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Pure aggregation, unit-tested. Slots are 15 minutes, so totals at the period edges are exact
    /// to the slot; the totals cards use the same slots for consistency with the chart.
    nonisolated static func makeReport(
        slots: [UsageSlot], period: AnalyticsPeriod, start: Date, end: Date,
        profileFilter: UUID?, modelFilter: String?, names: [UUID: String], calendar: Calendar, coverageStart: Date?
    ) -> AnalyticsReport {
        let previousStart = start.addingTimeInterval(-period.duration)
        let filtered = slots.filter { slot in
            (profileFilter == nil || slot.profileID == profileFilter) && (modelFilter == nil || slot.model == modelFilter)
        }
        var current = TokenTotals()
        var previous = TokenTotals()
        var byProfile: [UUID: TokenTotals] = [:]
        var byModel: [String: TokenTotals] = [:]
        var buckets: [Date: TokenTotals] = [:]
        for slot in filtered {
            if slot.slotStart >= start, slot.slotStart < end {
                current += slot.totals
                byProfile[slot.profileID, default: TokenTotals()] += slot.totals
                byModel[slot.model, default: TokenTotals()] += slot.totals
                buckets[period.bucket.start(of: slot.slotStart, calendar: calendar), default: TokenTotals()] += slot.totals
            } else if slot.slotStart >= previousStart, slot.slotStart < start {
                previous += slot.totals
            }
        }
        // Every bucket in the period, including empty ones, so gaps show as gaps.
        var series: [AnalyticsReport.Point] = []
        var cursor = period.bucket.start(of: start, calendar: calendar)
        while cursor < end {
            let next = period.bucket.next(after: cursor, calendar: calendar)
            series.append(AnalyticsReport.Point(start: cursor, end: next, totals: buckets[cursor] ?? TokenTotals()))
            cursor = next
        }
        let profileShares = byProfile.map { AnalyticsReport.Share(id: $0.key.uuidString, label: names[$0.key] ?? "Removed profile", totals: $0.value) }
            .sorted { $0.totals.total > $1.totals.total }
        let modelShares = byModel.map { AnalyticsReport.Share(id: $0.key, label: ModelName.display($0.key), totals: $0.value) }
            .sorted { $0.totals.total > $1.totals.total }
        return AnalyticsReport(period: period, start: start, end: end, current: current, previous: previous, series: series,
                               byProfile: profileShares, byModel: modelShares, coverageStart: coverageStart)
    }
}

/// Human names for model ids: `claude-opus-5-5` → "Opus 5.5", `claude-sonnet-4-5-20250929` → "Sonnet 4.5".
enum ModelName {
    static func display(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        // Family is the first all-letter part ("opus"); numbers anywhere form the version.
        guard let family = parts.first(where: { $0.allSatisfy(\.isLetter) }) else { return id }
        let version = parts.filter { Int($0) != nil }
        let suffix = parts.filter { Int($0) == nil && $0 != family }
        var name = family.prefix(1).uppercased() + family.dropFirst()
        if !version.isEmpty { name += " " + version.joined(separator: ".") }
        if !suffix.isEmpty { name += " " + suffix.joined(separator: " ") }
        return name
    }
}
