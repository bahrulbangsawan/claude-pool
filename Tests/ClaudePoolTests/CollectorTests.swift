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
    private func run(_ input: Data, arguments: [String]? = nil) throws -> ProcessOutput {
        try runProcess(
            binary, arguments ?? ["--profile", profileID.uuidString],
            environment: [PoolPaths.homeOverrideVariable: pool.home.path, "PATH": "/usr/bin:/bin", "HOME": temp.url.path],
            stdin: input
        )
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
        #expect(entry.sd == nil && entry.sdr == nil, "only windows present in that run are recorded")
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
