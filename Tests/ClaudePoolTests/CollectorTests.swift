import Foundation
import Testing
@testable import ClaudePool

/// Runs the built `claude-pool-collector` binary as a subprocess against a temp pool home.
@Suite(.serialized) struct CollectorTests {
    let temp: TempDirectory
    let pool: PoolPaths
    let binary: URL
    let profileID = UUID()

    init() throws {
        temp = try TempDirectory()
        pool = PoolPaths(home: temp.url.appendingPathComponent("pool", isDirectory: true))
        binary = try collectorBinary()
    }

    @discardableResult
    private func run(_ input: Data, arguments: [String]? = nil, configDir: String? = nil) throws -> ProcessOutput {
        var environment = [PoolPaths.homeOverrideVariable: pool.home.path, "PATH": "/usr/bin:/bin", "HOME": temp.url.path]
        environment["CLAUDE_CONFIG_DIR"] = configDir
        return try runProcess(binary, arguments ?? ["--profile", profileID.uuidString], environment: environment, stdin: input)
    }

    private func snapshot() throws -> UsageSnapshot {
        try UsageCoding.makeDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: pool.snapshot(for: profileID)))
    }

    private func historyLines() -> [String] {
        (readText(pool.history(for: profileID)) ?? "").split(separator: "\n").map(String.init)
    }

    private func allPoolFileContents() throws -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: pool.home, includingPropertiesForKeys: nil) else { return "" }
        var text = ""
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                text += (readText(url) ?? "") + "\n"
            }
        }
        return text
    }

    // MARK: Data minimisation

    @Test func fullPayloadStoresOnlySchemaKeys() throws {
        let result = try run(Fixtures.data("statusline-full.json"))
        #expect(result.status == 0)

        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: pool.snapshot(for: profileID))) as? [String: Any])
        #expect(Set(raw.keys) == ["schema", "profileId", "observedAt", "lastSeenAt", "claudeVersion", "fiveHour", "sevenDay"])
        #expect(Set((raw["fiveHour"] as? [String: Any])?.keys ?? [:].keys) == ["usedPercentage", "resetsAt"])
        #expect(Set((raw["sevenDay"] as? [String: Any])?.keys ?? [:].keys) == ["usedPercentage", "resetsAt"])

        let snap = try snapshot()
        #expect(snap.schema == 1)
        #expect(snap.profileId == profileID)
        #expect(snap.claudeVersion == "2.1.296")
        #expect(snap.fiveHour == UsageWindow(usedPercentage: 23.4, resetsAt: Date(timeIntervalSince1970: 1_791_000_000)))
        #expect(snap.sevenDay == UsageWindow(usedPercentage: 41, resetsAt: Date(timeIntervalSince1970: 1_791_500_000)))
        #expect(snap.observedAt != nil)

        // Nothing else from the payload appears anywhere in the files the collector wrote.
        let everything = try allPoolFileContents()
        // (Non-numeric probes only: digits could collide with the random UUID or timestamps.)
        for forbidden in ["/Users/example", "secret-project", "jsonl", "4f4ea72c-d657", "total_cost", "cost", "tokens",
                          "session", "Opus", "claude-opus", "security-reviewer", "NORMAL", "context", "cwd", "workspace",
                          "hook_event", "output_style", "exceeds", "vim", "agent", "model"] {
            #expect(!everything.contains(forbidden), "found \(forbidden) in collector output files")
        }
        #expect(!everything.lowercased().contains("transcript"))
        #expect(permissions(of: pool.snapshot(for: profileID)) == 0o600)
        #expect(permissions(of: pool.history(for: profileID)) == 0o600)
    }

    @Test func absentWindowsKeepPreviousValues() throws {
        try run(Fixtures.data("statusline-full.json"))
        let first = try snapshot()
        try run(Fixtures.data("statusline-partial.json"))
        let second = try snapshot()
        #expect(second.fiveHour?.usedPercentage == 57)
        #expect(second.sevenDay == first.sevenDay)
        #expect(second.claudeVersion == "2.1.297")

        try run(Fixtures.data("statusline-no-ratelimits.json"))
        let third = try snapshot()
        #expect(third.fiveHour == second.fiveHour)
        #expect(third.sevenDay == second.sevenDay)
        #expect(third.observedAt == second.observedAt, "observedAt only moves when a window is present")
        #expect(third.lastSeenAt >= second.lastSeenAt)
    }

    @Test func staleReportsFromIdleSessionsAreIgnored() throws {
        let reset = Int(Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970)
        func sevenDay(_ used: Int, resetsAt: Int) -> Data {
            Data(#"{"rate_limits":{"seven_day":{"used_percentage":\#(used),"resets_at":\#(resetsAt)}}}"#.utf8)
        }
        try run(sevenDay(99, resetsAt: reset))
        let live = try snapshot()

        try run(sevenDay(6, resetsAt: reset))
        try run(sevenDay(31, resetsAt: reset))
        let afterStale = try snapshot()
        #expect(afterStale.sevenDay?.usedPercentage == 99, "lower values for the same window are old reports")
        #expect(afterStale.observedAt == live.observedAt)
        #expect(historyLines().count == 1)

        try run(sevenDay(50, resetsAt: reset - 7 * 86_400))
        #expect(try snapshot().sevenDay?.usedPercentage == 99, "a window that already ended is ignored")

        try run(sevenDay(2, resetsAt: reset + 7 * 86_400))
        #expect(try snapshot().sevenDay?.usedPercentage == 2, "a later window replaces the stored one")
    }

    /// The server can lower a window's usage (seen live: 100% → 77% with the same reset). Claude Code
    /// adds `rate_limits` only after a session's first API response, so after a gap with no collector
    /// runs every report comes from a session that started since, and a lower value is current.
    @Test func lowerValueAfterAGapReplacesTheStoredOne() throws {
        let reset = Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970.rounded()
        let lastSeen = Date().addingTimeInterval(-22 * 3600)
        let stored = UsageSnapshot(profileId: profileID, observedAt: lastSeen, lastSeenAt: lastSeen,
                                   sevenDay: UsageWindow(usedPercentage: 100, resetsAt: Date(timeIntervalSince1970: reset)))
        try FileManager.default.createDirectory(at: pool.usageDirectory, withIntermediateDirectories: true)
        try UsageCoding.makeEncoder().encode(stored).write(to: pool.snapshot(for: profileID))

        func sevenDay(_ used: Int) -> Data {
            Data(#"{"rate_limits":{"seven_day":{"used_percentage":\#(used),"resets_at":\#(Int(reset))}}}"#.utf8)
        }
        try run(sevenDay(77))
        #expect(try snapshot().sevenDay?.usedPercentage == 77)
        #expect(try snapshot().observedAt.map { $0 > lastSeen } == true)

        // Once sessions are reporting again, a lower value is an idle session's old report.
        try run(sevenDay(40))
        #expect(try snapshot().sevenDay?.usedPercentage == 77)
    }

    // MARK: Concurrent sessions

    private var fiveHourReset: Int { Int(Date().addingTimeInterval(2 * 3600).timeIntervalSince1970 / 600) * 600 }
    private var weekReset: Int { Int(Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970 / 3600) * 3600 }

    /// A status line payload from one session (the ID is only an example value).
    private func report(_ session: String, fh: Int? = nil, sd: Int? = nil) -> Data {
        var windows: [String] = []
        if let fh { windows.append(#""five_hour":{"used_percentage":\#(fh),"resets_at":\#(fiveHourReset)}"#) }
        if let sd { windows.append(#""seven_day":{"used_percentage":\#(sd),"resets_at":\#(weekReset)}"#) }
        return Data(#"{"session_id":"\#(session)","rate_limits":{\#(windows.joined(separator: ","))}}"#.utf8)
    }

    /// Skips the warm-up after an update, as if the collector had been tracking sessions for a while.
    private func pastWarmUp() throws {
        try FileManager.default.createDirectory(at: pool.usageDirectory, withIntermediateDirectories: true)
        let since = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        try Data(#"{"schema":1,"since":\#(since),"reporters":[]}"#.utf8).write(to: pool.reporters(for: profileID))
    }

    @Test func activeSessionCanLowerAValueAnIdleSessionKeepsRepeating() throws {
        try pastWarmUp()
        try run(report("idle", sd: 100))
        try run(report("active", sd: 100))
        try run(report("active", sd: 77))
        let lowered = try snapshot()
        #expect(lowered.sevenDay?.usedPercentage == 77, "the server lowered the weekly value (seen live: 100% → 77%)")

        try run(report("idle", sd: 100))
        #expect(try snapshot().sevenDay?.usedPercentage == 77, "the idle session only repeats its last API response")
        #expect(try snapshot().observedAt == lowered.observedAt, "a repeated old report is not a new observation")
    }

    @Test func newSessionReportsCurrentUsage() throws {
        // Claude Code adds rate_limits only after a session's first API response.
        try pastWarmUp()
        try run(report("old", sd: 100))
        try run(report("new", sd: 77))
        #expect(try snapshot().sevenDay?.usedPercentage == 77)
    }

    @Test func droppedWindowDoesNotMakeASessionCurrent() throws {
        try pastWarmUp()
        try run(report("idle", fh: 50, sd: 100))
        try run(report("active", sd: 77))
        // The idle session's 5-hour window reset, so Claude Code stopped sending it.
        try run(report("idle", sd: 100))
        #expect(try snapshot().sevenDay?.usedPercentage == 77)
    }

    @Test func concurrentSessionsDoNotFloodHistory() throws {
        try pastWarmUp()
        try run(report("idle", fh: 9, sd: 29))
        try run(report("active", fh: 10, sd: 30))
        for _ in 0..<5 {
            try run(report("idle", fh: 9, sd: 29))
            try run(report("active", fh: 10, sd: 30))
        }
        #expect(historyLines().count == 2, "repeated reports add nothing within five minutes")

        try run(report("active", fh: 11, sd: 30))
        try run(report("idle", fh: 9, sd: 29))
        #expect(historyLines().count == 3)
        let last = try JSONDecoder().decode(UsageHistoryEntry.self, from: Data(historyLines()[2].utf8))
        #expect(last.fh == 11 && last.sd == 30, "each entry holds both current windows")
        #expect(try snapshot().fiveHour?.usedPercentage == 11)
    }

    @Test func warmUpKeepsTheHighestValueFromSessionsAlreadyOpen() throws {
        // First runs after an update: every open session is new to the collector, idle ones included.
        try run(report("a", sd: 100))
        try run(report("b", sd: 77))
        #expect(try snapshot().sevenDay?.usedPercentage == 100)
    }

    @Test func sessionIDIsStoredOnlyAsAHash() throws {
        try run(Fixtures.data("statusline-full.json"))
        let text = try #require(readText(pool.reporters(for: profileID)))
        #expect(!text.contains("4f4ea72c"))
        #expect(text.range(of: #""k":"[0-9a-f]{16}""#, options: .regularExpression) != nil)
        #expect(permissions(of: pool.reporters(for: profileID)) == 0o600)
    }

    // MARK: Routing by config directory

    /// `profileID` is the Default profile here; `other` owns the `other` config directory.
    private func writeProfileDirectories(other: UUID) throws -> URL {
        let otherDir = temp.file("other")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let map = ProfileDirectories(defaultProfile: profileID, directories: [
            ProfileDirectories.canonical(temp.file("default").path): profileID,
            ProfileDirectories.canonical(otherDir.path): other,
        ])
        try FileManager.default.createDirectory(at: pool.home, withIntermediateDirectories: true)
        try UsageCoding.makeEncoder().encode(map).write(to: pool.profileDirectories)
        return otherDir
    }

    private func snapshot(for id: UUID) -> UsageSnapshot? {
        (try? Data(contentsOf: pool.snapshot(for: id))).flatMap { try? UsageCoding.makeDecoder().decode(UsageSnapshot.self, from: $0) }
    }

    @Test func reportGoesToTheProfileThatOwnsTheSessionsConfigDir() throws {
        // A session of another profile started in the home folder loads ~/.claude/settings.json as
        // project settings, so it runs the Default profile's status line command.
        let other = UUID()
        let otherDir = try writeProfileDirectories(other: other)
        try run(report("s1", sd: 77), configDir: otherDir.path)
        #expect(snapshot(for: other)?.sevenDay?.usedPercentage == 77)
        #expect(snapshot(for: profileID) == nil)
    }

    @Test func sessionWithoutConfigDirBelongsToDefault() throws {
        let other = UUID()
        _ = try writeProfileDirectories(other: other)
        try run(report("s1", sd: 40), arguments: ["--profile", other.uuidString])
        #expect(snapshot(for: profileID)?.sevenDay?.usedPercentage == 40)
        #expect(snapshot(for: other) == nil)
    }

    @Test func unknownConfigDirOrNoMapKeepsTheRequestedProfile() throws {
        try run(report("s1", sd: 10), configDir: temp.file("other").path)
        #expect(snapshot(for: profileID)?.sevenDay?.usedPercentage == 10, "no map yet")

        _ = try writeProfileDirectories(other: UUID())
        try run(report("s1", sd: 11), configDir: temp.file("not-a-profile").path)
        #expect(snapshot(for: profileID)?.sevenDay?.usedPercentage == 11)
    }

    @Test func recordOnlyIsNeverRerouted() throws {
        // Check Usage Now names the profile itself and runs without CLAUDE_CONFIG_DIR.
        let other = UUID()
        _ = try writeProfileDirectories(other: other)
        let result = try run(report("s1", sd: 55), arguments: ["--profile", other.uuidString, "--record-only"])
        #expect(result.stdout.isEmpty)
        #expect(snapshot(for: other)?.sevenDay?.usedPercentage == 55)
        #expect(snapshot(for: profileID) == nil)
    }

    @Test func runWithoutWindowsRecordsLastSeenOnly() throws {
        try run(Fixtures.data("statusline-no-ratelimits.json"))
        let snap = try snapshot()
        #expect(snap.observedAt == nil)
        #expect(snap.fiveHour == nil && snap.sevenDay == nil)
        #expect(historyLines().isEmpty)
    }

    // MARK: Failure handling

    @Test(arguments: ["", "not json", "[1,2,3]", "\"str\"", "{\"rate_limits\": "])
    func malformedInputChangesNothing(_ input: String) throws {
        try run(Fixtures.data("statusline-full.json"))
        let before = try Data(contentsOf: pool.snapshot(for: profileID))
        let historyBefore = historyLines()
        let result = try run(Data(input.utf8))
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(try Data(contentsOf: pool.snapshot(for: profileID)) == before)
        #expect(historyLines() == historyBefore)
    }

    @Test func malformedWindowIsTreatedAsAbsent() throws {
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":"lots"},"seven_day":{"used_percentage":12,"resets_at":1791500000}}}"#
        let result = try run(Data(input.utf8))
        #expect(result.stdoutText == "7d 12%")
        #expect(try snapshot().fiveHour == nil)
    }

    @Test(arguments: [[String](), ["--profile"], ["--profile", "not-a-uuid"], ["--other", "x"]])
    func badArgumentsExitZeroSilently(_ arguments: [String]) throws {
        let result = try run(Fixtures.data("statusline-full.json"), arguments: arguments)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pool.usageDirectory.path))
    }

    @Test func inputOverOneMiBIsIgnored() throws {
        let window = #""rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1791000000}}"#
        let overhead = "{\"pad\":\"\",\(window)}".utf8.count
        let tooBig = "{\"pad\":\"\(String(repeating: "x", count: (1 << 20) - overhead + 1))\",\(window)}"
        #expect(tooBig.utf8.count == (1 << 20) + 1)
        let result = try run(Data(tooBig.utf8))
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pool.snapshot(for: profileID).path))

        let justFits = "{\"pad\":\"\(String(repeating: "x", count: (1 << 20) - overhead))\",\(window)}"
        #expect(justFits.utf8.count == 1 << 20)
        #expect(try run(Data(justFits.utf8)).stdoutText == "5h 5%")
        #expect(try snapshot().fiveHour?.usedPercentage == 5)
    }

    // MARK: Output

    @Test func summaryOutput() throws {
        #expect(try run(Fixtures.data("statusline-full.json")).stdoutText == "5h 23% · 7d 41%")
        #expect(try run(Fixtures.data("statusline-partial.json")).stdoutText == "5h 57%")
        #expect(try run(Fixtures.data("statusline-no-ratelimits.json")).stdout.isEmpty)
    }

    @Test func noneOutputMode() throws {
        try FileManager.default.createDirectory(at: pool.home, withIntermediateDirectories: true)
        try Data("none".utf8).write(to: pool.collectorOutputSetting)
        let result = try run(Fixtures.data("statusline-full.json"))
        #expect(result.stdout.isEmpty)
        #expect(try snapshot().fiveHour != nil)
    }

    @Test func chainPassthroughGetsSameStdin() throws {
        try FileManager.default.createDirectory(at: pool.chainDirectory, withIntermediateDirectories: true)
        try Data("cat".utf8).write(to: pool.chainCommand(for: profileID))
        let input = try Fixtures.data("statusline-full.json")
        let result = try run(input)
        #expect(result.stdout == input)
        #expect(try snapshot().fiveHour != nil, "the snapshot is still recorded when chaining")
    }

    @Test func chainOutputIsForwarded() throws {
        try FileManager.default.createDirectory(at: pool.chainDirectory, withIntermediateDirectories: true)
        try Data(#"cat >/dev/null; printf 'my \033[1mline\033[0m'"#.utf8).write(to: pool.chainCommand(for: profileID))
        let result = try run(Fixtures.data("statusline-partial.json"))
        #expect(result.stdoutText == "my \u{1B}[1mline\u{1B}[0m")
    }

    @Test func failingChainPrintsNothing() throws {
        try FileManager.default.createDirectory(at: pool.chainDirectory, withIntermediateDirectories: true)
        try Data("echo partial; exit 3".utf8).write(to: pool.chainCommand(for: profileID))
        let result = try run(Fixtures.data("statusline-full.json"))
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func chainTimeoutIsEnforced() throws {
        try FileManager.default.createDirectory(at: pool.chainDirectory, withIntermediateDirectories: true)
        try Data("sleep 6; echo late".utf8).write(to: pool.chainCommand(for: profileID))
        let result = try run(Fixtures.data("statusline-full.json"))
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.elapsed < 3.5, "took \(result.elapsed)s")
        #expect(result.elapsed >= 1.9)
    }

    // MARK: History

    @Test func historyIsThrottled() throws {
        let full = try Fixtures.data("statusline-full.json")
        try run(full)
        try run(full)
        try run(full)
        #expect(historyLines().count == 1, "unchanged values within 5 minutes are not repeated")

        try run(Fixtures.data("statusline-partial.json"))
        #expect(historyLines().count == 2, "changed values are recorded")

        try run(Fixtures.data("statusline-no-ratelimits.json"))
        #expect(historyLines().count == 2, "runs without windows add nothing")

        let entry = try JSONDecoder().decode(UsageHistoryEntry.self, from: Data(historyLines()[1].utf8))
        #expect(entry.fh == 57 && entry.fhr == 1_791_003_600)
        #expect(entry.sd == nil && entry.sdr == nil, "a window that has already reset is not carried into later entries")
    }

    @Test func historyRepeatsAfterFiveMinutes() throws {
        try FileManager.default.createDirectory(at: pool.usageDirectory, withIntermediateDirectories: true)
        let old = UsageHistoryEntry(t: Date().addingTimeInterval(-301).timeIntervalSince1970.rounded(), fh: 23.4, fhr: 1_791_000_000, sd: 41, sdr: 1_791_500_000)
        var line = try UsageCoding.makeEncoder().encode(old)
        line.append(UInt8(ascii: "\n"))
        try line.write(to: pool.history(for: profileID))
        try run(Fixtures.data("statusline-full.json"))
        #expect(historyLines().count == 2)
    }

    @Test func isFast() throws {
        let input = try Fixtures.data("statusline-full.json")
        try run(input) // warm up (first launch of a fresh binary is slower)
        let times = try (0..<5).map { _ in try run(input).elapsed }
        // Includes process spawn from the test runner; the collector's own budget is 30 ms.
        #expect(try #require(times.min()) < 0.1, "fastest run \(times.min() ?? -1)s")
    }
}
