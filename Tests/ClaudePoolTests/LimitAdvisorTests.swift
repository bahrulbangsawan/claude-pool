import Foundation
import Testing
@testable import ClaudePool

@Suite struct LimitAlertTrackerTests {
    static let now = Date(timeIntervalSince1970: 1_791_805_920)
    let id = UUID()
    let reset = now.addingTimeInterval(3_600)

    private func fresh(_ percent: Double, resetsAt: Date? = nil) -> UsageWindowState {
        .fresh(UsageWindow(usedPercentage: percent, resetsAt: resetsAt ?? reset), observedAt: Self.now)
    }

    private func obs(_ state: UsageWindowState, kind: UsageWindowKind = .fiveHour) -> LimitAlertTracker.Observation {
        .init(profileID: id, kind: kind, state: state)
    }

    @Test func firstUpdateOnlyPrimes() {
        var tracker = LimitAlertTracker()
        #expect(tracker.update([obs(fresh(95))], threshold: 90).isEmpty)
        #expect(tracker.isPrimed)
        // Same level again: still nothing.
        #expect(tracker.update([obs(fresh(96))], threshold: 90).isEmpty)
    }

    @Test func crossingThresholdThenLimitAlertsOnceEach() {
        var tracker = LimitAlertTracker()
        _ = tracker.update([obs(fresh(50))], threshold: 90)
        let near = tracker.update([obs(fresh(91))], threshold: 90)
        #expect(near.map(\.level) == [.near])
        #expect(near.first?.percent == 91)
        #expect(tracker.update([obs(fresh(94))], threshold: 90).isEmpty)
        let reached = tracker.update([obs(fresh(100))], threshold: 90)
        #expect(reached.map(\.level) == [.reached])
        #expect(tracker.update([obs(fresh(100))], threshold: 90).isEmpty)
    }

    @Test func jumpStraightToLimitIsOneEvent() {
        var tracker = LimitAlertTracker()
        _ = tracker.update([obs(fresh(10))], threshold: 90)
        #expect(tracker.update([obs(fresh(100))], threshold: 90).map(\.level) == [.reached])
    }

    @Test func newResetPeriodAlertsAgain() {
        var tracker = LimitAlertTracker()
        _ = tracker.update([obs(fresh(50))], threshold: 90)
        #expect(tracker.update([obs(fresh(92))], threshold: 90).count == 1)
        // Small jitter in the reported reset time is the same period.
        #expect(tracker.update([obs(fresh(93, resetsAt: reset.addingTimeInterval(30)))], threshold: 90).isEmpty)
        let next = reset.addingTimeInterval(5 * 3_600)
        #expect(tracker.update([obs(fresh(5, resetsAt: next))], threshold: 90).isEmpty)
        #expect(tracker.update([obs(fresh(91, resetsAt: next))], threshold: 90).map(\.level) == [.near])
    }

    @Test func staleAndMissingValuesNeverAlert() {
        var tracker = LimitAlertTracker()
        _ = tracker.update([obs(fresh(10))], threshold: 90)
        let stale = UsageWindowState.stale(UsageWindow(usedPercentage: 100, resetsAt: reset), observedAt: Self.now)
        #expect(tracker.update([obs(stale), obs(.noData, kind: .sevenDay), obs(.signedOut)], threshold: 90).isEmpty)
    }

    @Test func windowsAreTrackedSeparately() {
        var tracker = LimitAlertTracker()
        _ = tracker.update([obs(fresh(10)), obs(fresh(10), kind: .sevenDay)], threshold: 90)
        let events = tracker.update([obs(fresh(10)), obs(fresh(95), kind: .sevenDay)], threshold: 90)
        #expect(events.map(\.kind) == [.sevenDay])
    }

    @Test func forgottenProfileStartsOver() {
        var tracker = LimitAlertTracker()
        _ = tracker.update([obs(fresh(10))], threshold: 90)
        _ = tracker.update([obs(fresh(95))], threshold: 90)
        tracker.forget(id)
        #expect(tracker.update([obs(fresh(95))], threshold: 90).map(\.level) == [.near])
    }
}

@Suite struct AccountAdvisorTests {
    static let now = Date(timeIntervalSince1970: 1_791_805_920)

    private func window(_ percent: Double?, stale: Bool = false) -> UsageWindowState {
        guard let percent else { return .noData }
        let w = UsageWindow(usedPercentage: percent, resetsAt: Self.now.addingTimeInterval(3_600))
        return stale ? .stale(w, observedAt: Self.now) : .fresh(w, observedAt: Self.now)
    }

    private func candidate(_ five: Double?, _ seven: Double?, signedIn: Bool? = true, stale: Bool = false) -> AccountAdvisor.Candidate {
        .init(profileID: UUID(), fiveHour: window(five, stale: stale), sevenDay: window(seven, stale: stale), signedIn: signedIn)
    }

    @Test func noSuggestionWhileActiveIsFine() {
        let active = candidate(40, 60)
        #expect(AccountAdvisor.suggest(active: active, others: [candidate(5, 5)], threshold: 90) == nil)
    }

    @Test func suggestsLowestLoadWhenActiveIsNearLimit() {
        let active = candidate(92, 40)
        let busy = candidate(10, 70)   // load 70
        let roomy = candidate(30, 20)  // load 30
        let pick = AccountAdvisor.suggest(active: active, others: [active, busy, roomy], threshold: 90)
        #expect(pick?.profileID == roomy.profileID)
    }

    @Test func limitedActiveTriggersSuggestion() {
        let active = candidate(100, 50)
        let other = candidate(20, 20)
        #expect(AccountAdvisor.suggest(active: active, others: [other], threshold: 95)?.profileID == other.profileID)
    }

    @Test func skipsSignedOutUnknownLimitedAndNearAccounts() {
        let active = candidate(100, 50)
        let others = [
            candidate(5, 5, signedIn: false),
            candidate(nil, nil),
            candidate(100, 10),
            candidate(91, 10),
        ]
        #expect(AccountAdvisor.suggest(active: active, others: others, threshold: 90) == nil)
    }

    @Test func prefersFreshOverStaleThenOrder() {
        let active = candidate(100, 50)
        let staleLow = candidate(5, 5, stale: true)
        let freshA = candidate(40, 40)
        let freshB = candidate(40, 40)
        let pick = AccountAdvisor.suggest(active: active, others: [staleLow, freshA, freshB], threshold: 90)
        #expect(pick?.profileID == freshA.profileID)
    }
}

@Suite struct MenuBarTextTests {
    let reset = Date(timeIntervalSince1970: 1_791_805_920)

    @Test func usageShowsBothWindows() {
        let five = UsageWindow(usedPercentage: 23.4, resetsAt: reset)
        let seven = UsageWindow(usedPercentage: 41, resetsAt: reset)
        #expect(MenuBarText.usage(fiveHour: five, sevenDay: seven) == "5h:23% · 7d:41%")
        #expect(MenuBarText.usage(fiveHour: nil, sevenDay: seven) == "5h:– · 7d:41%")
        #expect(MenuBarText.usage(fiveHour: nil, sevenDay: nil) == nil)
    }

    @Test func systemText() {
        let gib: UInt64 = 1 << 30
        #expect(MenuBarText.system(.init(cpuPercent: 12.4, memoryUsed: 16 * gib, memoryTotal: 32 * gib)) == "CPU 12% · MEM 50%")
        #expect(MenuBarText.system(.init(cpuPercent: nil, memoryUsed: 8 * gib, memoryTotal: 32 * gib)) == "CPU – · MEM 25%")
        #expect(MenuBarText.system(nil) == nil)
    }

    @Test func cpuText() {
        #expect(MenuBarText.cpu(nil) == "–")
        #expect(MenuBarText.cpu(0.25) == "0.2%" || MenuBarText.cpu(0.25) == "0.3%")
        #expect(MenuBarText.cpu(142.6) == "143%")
    }
}

@Suite struct ResourceSamplerTests {
    @Test func cpuPercentFromTicks() {
        let a = ResourceSampler.CPUTicks(busy: 100, total: 1_000)
        let b = ResourceSampler.CPUTicks(busy: 350, total: 2_000)
        #expect(ResourceSampler.cpuPercent(from: a, to: b) == 25)
        #expect(ResourceSampler.cpuPercent(from: b, to: a) == nil)
    }

    @Test func processPercentIsPerCore() {
        // 3 s of CPU over 2 s of wall time = 150% (one and a half cores).
        #expect(ResourceSampler.processCPUPercent(cpuDelta: 3_000_000_000, wallDelta: 2) == 150)
        #expect(ResourceSampler.processCPUPercent(cpuDelta: 1, wallDelta: 0) == nil)
    }

    @Test func readsLiveCounters() throws {
        let ticks = try #require(ResourceSampler.cpuTicks())
        #expect(ticks.total > 0 && ticks.busy <= ticks.total)
        let memory = try #require(ResourceSampler.memory())
        #expect(memory.used > 0 && memory.used <= memory.total)
        let own = try #require(ResourceSampler.process(getpid()))
        #expect(own.footprint > 1_000_000)
        #expect(ResourceSampler.process(-1) == nil)
    }

    @Test func ownCPUTimeIsInNanoseconds() throws {
        func rusageNanoseconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let user = Double(usage.ru_utime.tv_sec) * 1e9 + Double(usage.ru_utime.tv_usec) * 1e3
            return user + Double(usage.ru_stime.tv_sec) * 1e9 + Double(usage.ru_stime.tv_usec) * 1e3
        }
        let before = try #require(ResourceSampler.process(getpid()))
        let reference = rusageNanoseconds()
        let start = ProcessInfo.processInfo.systemUptime
        var x = 0.0
        while ProcessInfo.processInfo.systemUptime - start < 0.2 { x += sin(x) + 1 }
        #expect(x > 0)
        let after = try #require(ResourceSampler.process(getpid()))
        let referenceDelta = rusageNanoseconds() - reference
        // Same process, same interval: a wrong Mach-time conversion would be off by ~40x.
        let ratio = Double(after.cpuNanoseconds - before.cpuNanoseconds) / referenceDelta
        #expect(ratio > 0.5 && ratio < 2)
    }

    @MainActor @Test func storeSumsSessions() {
        let store = ResourceStore()
        let pid = getpid()
        store.start(pids: { [pid] })
        store.stop()
        // Host CPU ticks advance every 10 ms; give them time to move.
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.05 {}
        store.sample(uptime: ProcessInfo.processInfo.systemUptime + 1)
        let usage = store.usage(for: pid)
        #expect(usage != nil && usage?.cpuPercent != nil)
        #expect(store.system?.cpuPercent != nil)
        #expect(store.total(for: [pid, -1])?.memory == usage?.memory)
        #expect(store.total(for: [-1]) == nil)
    }
}
