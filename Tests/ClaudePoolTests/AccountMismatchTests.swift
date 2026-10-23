import Foundation
import Testing
@testable import ClaudePool

@Suite struct AccountMismatchTests {
    let now = Date(timeIntervalSince1970: 1_792_716_000)

    private func snapshot(fiveHourIn: TimeInterval? = nil, sevenDayIn: TimeInterval? = nil) -> UsageSnapshot {
        UsageSnapshot(
            profileId: UUID(), observedAt: now, lastSeenAt: now,
            fiveHour: fiveHourIn.map { UsageWindow(usedPercentage: 10, resetsAt: now.addingTimeInterval($0)) },
            sevenDay: sevenDayIn.map { UsageWindow(usedPercentage: 10, resetsAt: now.addingTimeInterval($0)) }
        )
    }

    @Test func differentWeeklyResetsDisagree() {
        // Seen live: two profiles showing the same email, one resetting Thursday 20:00, the other Monday 10:00.
        #expect(AccountMismatch.windowsDisagree(snapshot(sevenDayIn: 6 * 86_400), snapshot(sevenDayIn: 3 * 86_400), now: now))
    }

    @Test func differentFiveHourResetsDisagree() {
        #expect(AccountMismatch.windowsDisagree(snapshot(fiveHourIn: 4 * 3600), snapshot(fiveHourIn: 2 * 3600), now: now))
    }

    @Test func sameResetsAgree() {
        let a = snapshot(fiveHourIn: 3600, sevenDayIn: 86_400)
        let b = snapshot(fiveHourIn: 3600 + 30, sevenDayIn: 86_400 - 30)
        #expect(!AccountMismatch.windowsDisagree(a, b, now: now))
    }

    @Test func endedWindowsAreIgnored() {
        // An old report of a window that has already reset says nothing about the current one.
        #expect(!AccountMismatch.windowsDisagree(snapshot(sevenDayIn: -3600), snapshot(sevenDayIn: 3 * 86_400), now: now))
    }

    @Test func missingDataIsNotAMismatch() {
        #expect(!AccountMismatch.windowsDisagree(nil, snapshot(sevenDayIn: 86_400), now: now))
        #expect(!AccountMismatch.windowsDisagree(snapshot(fiveHourIn: 3600), snapshot(sevenDayIn: 86_400), now: now))
    }

    @MainActor
    @Test func modelFlagsOnlySameAccountProfilesWithDifferentResets() throws {
        let temp = try TempDirectory()
        let paths = temp.paths
        try FileManager.default.createDirectory(at: paths.defaultConfigDir, withIntermediateDirectories: true)
        let model = AppModel(paths: paths, loginShell: "/bin/zsh", bundledHelper: try collectorBinary())
        model.liveChecksEnabled = false
        model.profileStore.load()
        let first = try #require(model.profileStore.defaultProfile)
        let second = try model.profileStore.add(name: "Second", slug: "second", configDir: paths.userHome.appendingPathComponent(".claude-second").path)
        let third = try model.profileStore.add(name: "Third", slug: "third", configDir: paths.userHome.appendingPathComponent(".claude-third").path)

        let now = Date()
        try AtomicFile.ensureDirectory(paths.pool.usageDirectory)
        func usage(_ id: UUID, weeklyResetIn: TimeInterval) throws {
            let s = UsageSnapshot(profileId: id, observedAt: now, lastSeenAt: now,
                                  sevenDay: UsageWindow(usedPercentage: 50, resetsAt: now.addingTimeInterval(weeklyResetIn)))
            try AtomicFile.write(UsageCoding.makeEncoder().encode(s), to: paths.pool.snapshot(for: id))
        }
        func signedIn(_ email: String) -> AuthStatus {
            AuthStatus(signedIn: true, authMethod: "claude.ai", checkedAt: now, email: email, orgId: "org-1")
        }
        try usage(first.id, weeklyResetIn: 6 * 86_400)
        try usage(second.id, weeklyResetIn: 3 * 86_400)
        try usage(third.id, weeklyResetIn: 2 * 86_400)
        model.usageStore.reload()
        model.authStore.record(signedIn("me@example.com"), for: first.id)
        model.authStore.record(signedIn("me@example.com"), for: second.id)
        model.authStore.record(signedIn("other@example.com"), for: third.id)

        #expect(model.accountMismatches(for: first).map(\.id) == [second.id])
        #expect(model.accountMismatches(for: second).map(\.id) == [first.id])
        #expect(model.accountMismatches(for: third).isEmpty, "different emails are simply different accounts")

        try usage(second.id, weeklyResetIn: 6 * 86_400)
        model.usageStore.reload()
        #expect(model.accountMismatches(for: first).isEmpty, "same resets fit one account")
    }
}
