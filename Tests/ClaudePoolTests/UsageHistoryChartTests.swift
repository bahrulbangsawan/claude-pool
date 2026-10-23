import Foundation
import Testing
@testable import ClaudePool

@MainActor
@Suite struct UsageHistoryChartTests {
    /// "time:value", with "r" for points added at a reset (not observations).
    private func line(_ entries: [UsageHistoryEntry], _ kind: UsageWindowKind, now: TimeInterval) -> [String] {
        UsageHistoryChart.points(from: entries, now: Date(timeIntervalSince1970: now))
            .filter { $0.window == kind }
            .map { "\(Int($0.date.timeIntervalSince1970)):\(Int($0.value))\($0.observed ? "" : "r")" }
    }

    @Test func valuesHoldUntilTheResetThenDropToZero() {
        let entries = [
            UsageHistoryEntry(t: 100, fh: 10, fhr: 1000),
            UsageHistoryEntry(t: 500, fh: 30, fhr: 1000),
            UsageHistoryEntry(t: 1100, fh: 5, fhr: 19000),
        ]
        #expect(line(entries, .fiveHour, now: 2000) == ["100:10", "500:30", "1000:30r", "1000:0r", "1100:5"])
    }

    @Test func lastWindowDropsOnceItsResetHasPassed() {
        let entries = [UsageHistoryEntry(t: 100, sd: 40, sdr: 1000)]
        #expect(line(entries, .sevenDay, now: 2000) == ["100:40", "1000:40r", "1000:0r"])
        #expect(line(entries, .sevenDay, now: 500) == ["100:40"], "an open window ends at its last observation")
    }

    @Test func eachWindowIsItsOwnLine() {
        // Older history can have entries holding only one of the windows.
        let entries = [
            UsageHistoryEntry(t: 100, fh: 10, fhr: 1000, sd: 20, sdr: 9000),
            UsageHistoryEntry(t: 200, fh: 12, fhr: 1000),
            UsageHistoryEntry(t: 300, sd: 21, sdr: 9000),
        ]
        #expect(line(entries, .fiveHour, now: 500) == ["100:10", "200:12"])
        #expect(line(entries, .sevenDay, now: 500) == ["100:20", "300:21"])
    }

    @Test func resetTimesWithinAMinuteAreTheSameWindow() {
        let entries = [UsageHistoryEntry(t: 100, fh: 10, fhr: 1000), UsageHistoryEntry(t: 200, fh: 11, fhr: 1030)]
        #expect(line(entries, .fiveHour, now: 500) == ["100:10", "200:11"])
    }
}
