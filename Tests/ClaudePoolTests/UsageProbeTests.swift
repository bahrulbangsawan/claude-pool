import Foundation
import Testing
@testable import ClaudePool

@Suite struct UsageProbeTests {
    /// Shaped like `claude -p --output-format stream-json --verbose` from Claude Code 2.1.309.
    static let stream = """
    {"type":"system","subtype":"init","session_id":"s1","tools":[],"mcp_servers":[],"apiKeySource":"none"}
    {"type":"assistant","message":{"content":[{"type":"text","text":"OK, not a rate_limit_event"}]},"session_id":"s1"}
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1792732800,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.11,"resetsAt":1792732800},"seven_day":{"utilization":0.77,"resetsAt":1793275200}}},"uuid":"u1","session_id":"s1"}
    {"type":"result","subtype":"success","result":"OK","total_cost_usd":0.0001}

    """

    static let reading = UsageReading(
        fiveHour: .init(usedPercentage: 11, resetsAt: 1_792_732_800),
        sevenDay: .init(usedPercentage: 77, resetsAt: 1_793_275_200)
    )

    @Test func readsTheUsageEvent() {
        #expect(UsageProbe.parse(Data(Self.stream.utf8)) == Self.reading)
    }

    @Test func outputWithoutUsageIsNoReading() {
        let noWindows = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#
        #expect(UsageProbe.parse(Data(noWindows.utf8)) == nil)
        #expect(UsageProbe.parse(Data(#"{"type":"result","subtype":"success"}"#.utf8)) == nil)
        #expect(UsageProbe.parse(Data()) == nil)
    }

    @Test func oneWindowIsEnough() {
        // Team plans can report only the 5-hour window.
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.7,"resetsAt":1792725000}}}}"#
        #expect(UsageProbe.parse(Data(line.utf8)) == UsageReading(fiveHour: .init(usedPercentage: 70, resetsAt: 1_792_725_000), sevenDay: nil))
    }

    // MARK: Running claude

    private func fakeClaude(_ temp: TempDirectory, body: String) throws -> ClaudeBinary {
        let script = """
        #!/bin/sh
        for a in "$@"; do printf '[%s]' "$a"; done > "$HOME/args"
        printf '%s' "${CLAUDE_CONFIG_DIR-UNSET}" > "$HOME/config-dir"
        \(body)

        """
        let url = try temp.write(script, to: "bin/claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return ClaudeBinary(path: url.path, source: .fallback)
    }

    private func profile(_ temp: TempDirectory) -> Profile {
        var profile = Profile.makeDefault(home: temp.paths.userHome)
        profile.isDefault = false
        profile.configDir = temp.paths.userHome.appendingPathComponent(".claude-two").path
        return profile
    }

    @Test func checkSendsOneMinimalRequestAsTheProfile() async throws {
        let temp = try TempDirectory()
        try FileManager.default.createDirectory(at: temp.paths.userHome, withIntermediateDirectories: true)
        let claude = try fakeClaude(temp, body: "cat <<'EOF'\n\(Self.stream)EOF")
        let probe = UsageProbe(paths: temp.paths)

        let reading = try await probe.check(profile(temp), binary: claude)
        #expect(reading == Self.reading)
        #expect(readText(temp.paths.userHome.appendingPathComponent("config-dir")) == profile(temp).configDir)
        let args = try #require(readText(temp.paths.userHome.appendingPathComponent("args")))
        // Haiku, no tools, MCP servers, settings (so no hooks or plugins) or saved session.
        for expected in ["[-p]", "[--model][haiku]", "[--tools][]", "[--strict-mcp-config]", "[--setting-sources][]",
                         "[--no-session-persistence]", "[--output-format][stream-json]"] {
            #expect(args.contains(expected), "missing \(expected) in \(args)")
        }
    }

    @Test func checkWithoutUsageInTheOutputFails() async throws {
        let temp = try TempDirectory()
        try FileManager.default.createDirectory(at: temp.paths.userHome, withIntermediateDirectories: true)
        let claude = try fakeClaude(temp, body: #"echo '{"type":"result","subtype":"success"}'"#)
        await #expect(throws: UsageProbeError.notReported) {
            try await UsageProbe(paths: temp.paths).check(profile(temp), binary: claude)
        }
    }

    @Test func checkFailureCarriesClaudesMessage() async throws {
        let temp = try TempDirectory()
        try FileManager.default.createDirectory(at: temp.paths.userHome, withIntermediateDirectories: true)
        let claude = try fakeClaude(temp, body: "echo 'Invalid API key · Please run /login' >&2\nexit 1")
        await #expect(throws: UsageProbeError.failed("Invalid API key · Please run /login")) {
            try await UsageProbe(paths: temp.paths).check(profile(temp), binary: claude)
        }
    }

    // MARK: Recording

    @Test func recordGoesThroughTheCollectorAsANewSession() async throws {
        let temp = try TempDirectory()
        let profileID = UUID()
        var target = profile(temp)
        target = Profile(id: profileID, name: target.name, slug: target.slug, configDir: target.configDir, colorHex: target.colorHex,
                         isDefault: false, trackingEnabled: true, originalStatusLine: nil, sortIndex: 1, createdAt: Date())
        let future = UsageReading(
            fiveHour: .init(usedPercentage: 11, resetsAt: Date().addingTimeInterval(3600).timeIntervalSince1970.rounded()),
            sevenDay: .init(usedPercentage: 77, resetsAt: Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970.rounded())
        )
        try await UsageProbe(paths: temp.paths).record(future, for: target, collector: try collectorBinary())

        let data = try Data(contentsOf: temp.paths.pool.snapshot(for: profileID))
        let snapshot = try UsageCoding.makeDecoder().decode(UsageSnapshot.self, from: data)
        #expect(snapshot.sevenDay?.usedPercentage == 77)
        #expect(snapshot.fiveHour?.usedPercentage == 11)
        #expect(snapshot.observedAt != nil)
        #expect(FileManager.default.fileExists(atPath: temp.paths.pool.reporters(for: profileID).path))
    }
}
