import Foundation
import Testing
@testable import ClaudePool

@Suite struct UsageFormattingTests {
    /// Monday 2026-10-12 11:52:00 UTC
    static let now = Date(timeIntervalSince1970: 1_791_805_920)
    static let utc = TimeZone(identifier: "UTC")!
    let formatting = UsageFormatting(now: now, locale: Locale(identifier: "en_GB"), timeZone: utc)
    let id = UUID()

    private func auth(_ signedIn: Bool = true, method: String? = "claude.ai") -> AuthStatus {
        AuthStatus(signedIn: signedIn, authMethod: method, configDirectory: nil, identityLabel: nil, subscriptionType: nil, checkedAt: Self.now)
    }

    private func snapshot(observedAgo: TimeInterval?, fiveHourReset: TimeInterval = 7_980, percent: Double = 23) -> UsageSnapshot {
        UsageSnapshot(
            profileId: id,
            observedAt: observedAgo.map { Self.now.addingTimeInterval(-$0) },
            lastSeenAt: Self.now,
            fiveHour: observedAgo == nil ? nil : UsageWindow(usedPercentage: percent, resetsAt: Self.now.addingTimeInterval(fiveHourReset)),
            sevenDay: nil
        )
    }

    private func state(_ kind: UsageWindowKind = .fiveHour, tracking: Bool = true, auth: AuthStatus?, snapshot: UsageSnapshot?) -> UsageWindowState {
        UsageFormatting.state(for: kind, trackingEnabled: tracking, auth: auth, snapshot: snapshot, now: Self.now)
    }

    // MARK: State priority

    @Test func trackingOffWins() {
        #expect(state(tracking: false, auth: auth(false), snapshot: snapshot(observedAgo: 10)) == .trackingOff)
    }

    @Test func signedOutBeatsData() {
        #expect(state(auth: auth(false, method: "none"), snapshot: snapshot(observedAgo: 10)) == .signedOut)
    }

    @Test func nonSubscriptionSignInIsNotReported() {
        for method in ["api_key", "oauth_token", "api_key_helper", "third_party"] {
            #expect(state(auth: auth(method: method), snapshot: snapshot(observedAgo: 10)) == .notReported)
        }
    }

    @Test func runWithoutAnyWindowIsNotReported() {
        #expect(state(auth: auth(), snapshot: snapshot(observedAgo: nil)) == .notReported)
        #expect(state(auth: nil, snapshot: snapshot(observedAgo: nil)) == .notReported)
    }

    @Test func noSnapshotIsNoData() {
        #expect(state(auth: auth(), snapshot: nil) == .noData)
        #expect(state(auth: nil, snapshot: nil) == .noData)
        // A window that was never present while the other one was.
        #expect(state(.sevenDay, auth: auth(), snapshot: snapshot(observedAgo: 10)) == .noData)
    }

    @Test func resetPassedBeatsStaleAndFresh() {
        let snap = snapshot(observedAgo: 3_600, fiveHourReset: -60)
        let result = state(auth: auth(), snapshot: snap)
        #expect(result == .resetPassed(resetAt: Self.now.addingTimeInterval(-60)))
        #expect(result.displayedWindow == nil)
        // Exactly at the reset time counts as passed.
        #expect(state(auth: auth(), snapshot: snapshot(observedAgo: 10, fiveHourReset: 0)) == .resetPassed(resetAt: Self.now))
    }

    @Test func staleAfterFifteenMinutes() {
        let fresh = state(auth: auth(), snapshot: snapshot(observedAgo: 15 * 60))
        #expect(!fresh.isStale)
        let stale = state(auth: auth(), snapshot: snapshot(observedAgo: 15 * 60 + 1))
        #expect(stale.isStale)
        #expect(stale.displayedWindow?.usedPercentage == 23)
        #expect(formatting.observationText(stale) == "as of 15m ago")
    }

    @Test func freshShowsReportedValue() {
        let fresh = state(auth: auth(), snapshot: snapshot(observedAgo: 180))
        guard case let .fresh(window, observedAt) = fresh else {
            Issue.record("expected fresh, got \(fresh)")
            return
        }
        #expect(window.usedPercentage == 23)
        #expect(observedAt == Self.now.addingTimeInterval(-180))
        #expect(formatting.observationText(fresh) == "observed 3m ago")
    }

    // MARK: Text

    @Test func resetPassedNeverRendersZeroPercent() {
        let result = state(auth: auth(), snapshot: snapshot(observedAgo: 3_600, fiveHourReset: -60, percent: 0))
        let texts = [
            formatting.stateText(result, kind: .fiveHour) ?? "",
            formatting.accessibilityLabel(result, kind: .fiveHour),
        ]
        for text in texts {
            #expect(!text.contains("0%"))
            #expect(!text.contains("0 percent"))
        }
        #expect(formatting.stateText(result, kind: .fiveHour) == "Window reset at 11:51 · no newer data")
    }

    @Test func resetTextFiveHour() {
        let window = UsageWindow(usedPercentage: 23, resetsAt: Self.now.addingTimeInterval(2 * 3600 + 13 * 60))
        #expect(formatting.resetText(window, kind: .fiveHour) == "resets 14:05 · in 2h 13m")
    }

    @Test func resetTextSevenDay() {
        // Mon 11:52 → Thu 09:00 is 2d 21h 8m.
        let reset = Date(timeIntervalSince1970: 1_792_054_800) // Thu 15 Oct 2026 09:00 UTC
        let window = UsageWindow(usedPercentage: 41, resetsAt: reset)
        #expect(formatting.clockText(reset, for: .sevenDay) == "Thu 09:00")
        #expect(formatting.resetText(window, kind: .sevenDay) == "resets Thu 09:00 · in 2d 21h")
    }

    @Test func countdownFormatting() {
        let f = formatting
        #expect(f.countdown(to: Self.now.addingTimeInterval(2 * 3600 + 13 * 60 + 59)) == "2h 13m")
        #expect(f.countdown(to: Self.now.addingTimeInterval(3 * 86_400 + 4 * 3600 + 30)) == "3d 4h")
        #expect(f.countdown(to: Self.now.addingTimeInterval(45 * 60)) == "45m")
        #expect(f.countdown(to: Self.now.addingTimeInterval(30)) == "<1m")
        #expect(f.countdown(to: Self.now.addingTimeInterval(-30)) == "<1m")
        #expect(f.countdown(to: Self.now.addingTimeInterval(3600)) == "1h 0m")
    }

    @Test func ageFormatting() {
        let f = formatting
        #expect(f.age(since: Self.now.addingTimeInterval(-20)) == "just now")
        #expect(f.age(since: Self.now.addingTimeInterval(-4 * 60)) == "4m ago")
        #expect(f.age(since: Self.now.addingTimeInterval(-2 * 3600)) == "2h ago")
        #expect(f.age(since: Self.now.addingTimeInterval(-(2 * 3600 + 5 * 60))) == "2h 5m ago")
        #expect(f.age(since: Self.now.addingTimeInterval(-3 * 86_400)) == "3d ago")
    }

    @Test func percentAndLevels() {
        #expect(UsageFormatting.percentText(23.4) == "23%")
        #expect(UsageFormatting.percentText(23.5) == "24%")
        #expect(UsageFormatting.level(for: 69.4) == .normal)
        #expect(UsageFormatting.level(for: 69.5) == .elevated)
        #expect(UsageFormatting.level(for: 89.4) == .elevated)
        #expect(UsageFormatting.level(for: 89.5) == .critical)
        #expect(UsageFormatting.level(for: 100) == .critical)
    }

    @Test func voiceOverLabel() {
        let window = UsageWindow(usedPercentage: 23, resetsAt: Self.now.addingTimeInterval(2 * 3600 + 13 * 60))
        let fresh = UsageWindowState.fresh(window, observedAt: Self.now)
        #expect(formatting.accessibilityLabel(fresh, kind: .fiveHour) == "5-hour limit 23 percent, resets at 14:05")
        let stale = UsageWindowState.stale(window, observedAt: Self.now.addingTimeInterval(-1_800))
        #expect(formatting.accessibilityLabel(stale, kind: .fiveHour) == "5-hour limit 23 percent, resets at 14:05, as of 30m ago")
    }

    @Test func stateTexts() {
        #expect(formatting.stateText(.trackingOff, kind: .fiveHour) == "Usage tracking off")
        #expect(formatting.stateText(.signedOut, kind: .fiveHour) == "Signed out")
        #expect(formatting.stateText(.notReported, kind: .fiveHour) == "Not reported for this sign-in or plan")
        #expect(formatting.stateText(.noData, kind: .fiveHour)?.hasPrefix("No data yet") == true)
    }
}

struct AccountAvailabilityTests {
    let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func exhaustedWindowLimitsUntilItsReset() {
        let five = UsageWindowState.fresh(UsageWindow(usedPercentage: 100, resetsAt: now.addingTimeInterval(3_600)), observedAt: now)
        let seven = UsageWindowState.fresh(UsageWindow(usedPercentage: 40, resetsAt: now.addingTimeInterval(86_400)), observedAt: now)
        #expect(AccountAvailability.evaluate(fiveHour: five, sevenDay: seven, signedIn: true)
                == .limited(until: now.addingTimeInterval(3_600), kind: .fiveHour, stale: false))
        // When both are exhausted, the later reset is when it becomes usable again.
        let sevenFull = UsageWindowState.stale(UsageWindow(usedPercentage: 100.2, resetsAt: now.addingTimeInterval(86_400)), observedAt: now)
        #expect(AccountAvailability.evaluate(fiveHour: five, sevenDay: sevenFull, signedIn: true)
                == .limited(until: now.addingTimeInterval(86_400), kind: .sevenDay, stale: true))
    }

    @Test func otherStates() {
        let low = UsageWindowState.fresh(UsageWindow(usedPercentage: 20, resetsAt: now.addingTimeInterval(60)), observedAt: now)
        let high = UsageWindowState.fresh(UsageWindow(usedPercentage: 91, resetsAt: now.addingTimeInterval(60)), observedAt: now)
        #expect(AccountAvailability.evaluate(fiveHour: low, sevenDay: .noData, signedIn: true) == .available(nearLimit: false, stale: false))
        #expect(AccountAvailability.evaluate(fiveHour: high, sevenDay: .noData, signedIn: nil) == .available(nearLimit: true, stale: false))
        #expect(AccountAvailability.evaluate(fiveHour: .noData, sevenDay: .trackingOff, signedIn: true) == .unknown)
        // A reset that has passed is not treated as still exhausted.
        #expect(AccountAvailability.evaluate(fiveHour: .resetPassed(resetAt: now), sevenDay: .noData, signedIn: true) == .unknown)
        #expect(AccountAvailability.evaluate(fiveHour: high, sevenDay: high, signedIn: false) == .signedOut)
        #expect(UsageFormatting.remainingText(UsageWindow(usedPercentage: 23.4, resetsAt: now)) == "77% left")
        #expect(UsageFormatting.remainingText(UsageWindow(usedPercentage: 104, resetsAt: now)) == "0% left")
    }
}
