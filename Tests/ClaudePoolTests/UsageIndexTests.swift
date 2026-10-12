import Foundation
import Testing
@testable import ClaudePool

struct UsageIndexTests {
    /// One assistant line as Claude Code writes it (content included, to prove it is ignored).
    static func line(msg: String, req: String, at time: String, model: String = "claude-opus-5-5",
                     input: Int = 10, output: Int = 20, read: Int = 300, write: Int = 40, content: String = "SECRET-CONTENT") -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"assistant","uuid":"\#(UUID().uuidString)","timestamp":"\#(time)","requestId":"\#(req)","cwd":"/Users/x/secret-project","message":{"id":"\#(msg)","type":"message","role":"assistant","model":"\#(model)","content":[{"type":"text","text":"\#(content)"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"service_tier":"standard"}}}"#
    }

    static func userLine(_ text: String) -> String {
        #"{"type":"user","timestamp":"2026-10-11T06:00:00.000Z","message":{"role":"user","content":"\#(text) \"usage\" \"type\":\"assistant\""}}"#
    }

    private func setup() throws -> (TempDirectory, UsageIndex, URL, UUID) {
        let temp = try TempDirectory()
        let projects = temp.file("profile/projects")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-Users-x-proj"), withIntermediateDirectories: true)
        let index = try UsageIndex(url: temp.file("index/usage-index.sqlite"))
        return (temp, index, projects, UUID())
    }

    private let now = Date(timeIntervalSince1970: 1_791_800_000) // 2026-10-12

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @Test func duplicateBlocksOfOneResponseCountOnce() async throws {
        let (temp, index, projects, profile) = try setup()
        _ = temp
        let t = iso(now.addingTimeInterval(-3_600))
        // Same response written three times (one line per content block), plus a different response.
        let text = [Self.line(msg: "m1", req: "r1", at: t), Self.line(msg: "m1", req: "r1", at: t), Self.line(msg: "m1", req: "r1", at: t),
                    Self.line(msg: "m2", req: "r2", at: t, input: 1, output: 2, read: 3, write: 4),
                    Self.userLine("hello")].joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: projects.appendingPathComponent("-Users-x-proj/s1.jsonl"))
        let report = try await index.scan(profiles: [(profile, projects)], now: now)
        #expect(report.requestsAdded == 2)
        let totals = try await index.totals(from: now.addingTimeInterval(-86_400), to: now)
        #expect(totals == TokenTotals(input: 11, output: 22, cacheRead: 303, cacheCreation: 44, requests: 2))
        #expect(totals.total == 380)
    }

    /// Regression (found by cross-checking real data): while streaming, Claude Code may write an
    /// early copy of a response with a partial output count, then the final one. Keeping the first
    /// copy undercounted output tokens ~2.6x on a real 7-day sample.
    @Test func streamingCopiesMergeToFinalUsageAndEarliestTime() async throws {
        let (temp, index, projects, profile) = try setup()
        _ = temp
        let early = iso(now.addingTimeInterval(-7_200)), late = iso(now.addingTimeInterval(-7_100))
        // Final copy first in file order, partial copy (earlier timestamp) in a second file.
        try Data((Self.line(msg: "m", req: "r", at: late, output: 1_075) + "\n").utf8).write(to: projects.appendingPathComponent("-Users-x-proj/a.jsonl"))
        try Data((Self.line(msg: "m", req: "r", at: early, output: 3) + "\n").utf8).write(to: projects.appendingPathComponent("-Users-x-proj/b.jsonl"))
        _ = try await index.scan(profiles: [(profile, projects)], now: now)
        let totals = try await index.totals(from: now.addingTimeInterval(-86_400), to: now)
        #expect(totals.requests == 1)
        #expect(totals.output == 1_075)
        // Counted at the earliest time: a window ending between the two copies includes it.
        #expect(try await index.totals(from: now.addingTimeInterval(-7_150), to: now).requests == 0)
        #expect(try await index.totals(from: now.addingTimeInterval(-7_250), to: now.addingTimeInterval(-7_150)).requests == 1)
    }

    @Test func appendedLinesAreReadIncrementallyAndPartialLinesWait() async throws {
        let (temp, index, projects, profile) = try setup()
        _ = temp
        let file = projects.appendingPathComponent("-Users-x-proj/s1.jsonl")
        let t = iso(now.addingTimeInterval(-60))
        try Data((Self.line(msg: "a", req: "1", at: t) + "\n").utf8).write(to: file)
        _ = try await index.scan(profiles: [(profile, projects)], now: now)

        // A second response arrives, written in two parts: first without its newline.
        let second = Self.line(msg: "b", req: "2", at: t)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.prefix(40).utf8))
        var report = try await index.scan(profiles: [(profile, projects)], now: now)
        #expect(report.requestsAdded == 0)
        try handle.write(contentsOf: Data((second.dropFirst(40) + "\n").utf8))
        try handle.close()
        report = try await index.scan(profiles: [(profile, projects)], now: now)
        #expect(report.requestsAdded == 1)
        #expect(try await index.totals(from: now.addingTimeInterval(-3_600), to: now).requests == 2)

        // Unchanged files are skipped entirely.
        report = try await index.scan(profiles: [(profile, projects)], now: now)
        #expect(report.filesScanned == 0)
    }

    @Test func subagentFilesAndOtherProfilesAreIncludedAndDedupedAcrossThem() async throws {
        let (temp, index, projects, profile) = try setup()
        let other = temp.file("other/projects/-Users-x-proj")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let sub = projects.appendingPathComponent("-Users-x-proj/s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let t = iso(now.addingTimeInterval(-120))
        try Data((Self.line(msg: "a", req: "1", at: t) + "\n").utf8).write(to: projects.appendingPathComponent("-Users-x-proj/s1.jsonl"))
        try Data((Self.line(msg: "sub", req: "9", at: t) + "\n").utf8).write(to: sub.appendingPathComponent("agent-1.jsonl"))
        // A copy of the same response in another profile (e.g. copied conversation) is not double counted.
        try Data((Self.line(msg: "a", req: "1", at: t) + "\n").utf8).write(to: other.appendingPathComponent("s1.jsonl"))
        let otherID = UUID()
        _ = try await index.scan(profiles: [(profile, projects), (otherID, temp.file("other/projects"))], now: now)
        #expect(try await index.totals(from: now.addingTimeInterval(-3_600), to: now).requests == 2)
        #expect(try await index.totals(from: now.addingTimeInterval(-3_600), to: now, profiles: [otherID]).requests == 0)
    }

    @Test func handoffCopiesOnlyCountNewLinesForTheTarget() async throws {
        let (temp, index, projects, profile) = try setup()
        let target = temp.file("target/projects/-Users-x-proj")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let t = iso(now.addingTimeInterval(-600))
        let copied = target.appendingPathComponent("s1.jsonl")
        try Data((Self.line(msg: "old-unseen", req: "1", at: t) + "\n").utf8).write(to: copied)
        let targetID = UUID()
        try await index.markIndexed([(copied, SessionHandoffService.size(of: copied))], profileID: targetID)
        let handle = try FileHandle(forWritingTo: copied)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.line(msg: "new", req: "2", at: t) + "\n").utf8))
        try handle.close()
        _ = try await index.scan(profiles: [(profile, projects), (targetID, temp.file("target/projects"))], now: now)
        #expect(try await index.totals(from: now.addingTimeInterval(-3_600), to: now, profiles: [targetID]).requests == 1)
    }

    @Test func oldEntriesSyntheticAndEmptyUsageAreIgnored() async throws {
        let (temp, index, projects, profile) = try setup()
        _ = temp
        let old = iso(now.addingTimeInterval(-90 * 86_400))
        let recent = iso(now.addingTimeInterval(-60))
        let text = [Self.line(msg: "old", req: "1", at: old),
                    Self.line(msg: "syn", req: "2", at: recent, model: "<synthetic>"),
                    Self.line(msg: "zero", req: "3", at: recent, input: 0, output: 0, read: 0, write: 0),
                    "not json at all \"type\":\"assistant\" \"usage\"",
                    Self.line(msg: "ok", req: "4", at: recent)].joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: projects.appendingPathComponent("-Users-x-proj/s.jsonl"))
        _ = try await index.scan(profiles: [(profile, projects)], now: now)
        #expect(try await index.totals(from: .distantPast, to: now).requests == 1)
    }

    @Test func indexStoresNoContentOrPaths() async throws {
        let (temp, index, projects, profile) = try setup()
        try Data((Self.line(msg: "m", req: "r", at: iso(now.addingTimeInterval(-60))) + "\n").utf8)
            .write(to: projects.appendingPathComponent("-Users-x-proj/s.jsonl"))
        _ = try await index.scan(profiles: [(profile, projects)], now: now)
        let bytes = try Data(contentsOf: temp.file("index/usage-index.sqlite"))
            + ((try? Data(contentsOf: temp.file("index/usage-index.sqlite-wal"))) ?? Data())
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("SECRET-CONTENT"))
        #expect(!text.contains("secret-project"))
        #expect(permissions(of: temp.file("index/usage-index.sqlite")) == 0o600)
    }

    @Test func timestampParserMatchesFoundation() {
        for text in ["2026-10-11T06:13:59.592Z", "2026-02-28T23:59:59Z", "2024-02-29T12:00:00.5Z", "1999-12-31T00:00:00.000Z"] {
            let expected = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: text.contains(".")))
            let parsed = UsageLine.parseTimestamp(text)
            #expect(parsed != nil)
            #expect(abs((parsed ?? 0) - (expected?.timeIntervalSince1970 ?? -1)) < 0.001, "\(text)")
        }
        #expect(UsageLine.parseTimestamp("2026-10-11T06:13:59+02:00") == (try? Date("2026-10-11T06:13:59+02:00", strategy: .iso8601))?.timeIntervalSince1970)
        #expect(UsageLine.parseTimestamp("garbage") == nil)
    }
}

struct AnalyticsReportTests {
    @Test func reportBucketsComparesAndFilters() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kathmandu")! // +5:45, a non-whole-hour offset
        let end = Date(timeIntervalSince1970: 1_791_800_000)
        let start = end.addingTimeInterval(-86_400)
        let a = UUID(), b = UUID()
        func slot(_ ago: TimeInterval, _ profile: UUID, _ model: String, _ input: Int64) -> UsageSlot {
            let t = (end.addingTimeInterval(-ago).timeIntervalSince1970 / UsageIndex.slotSeconds).rounded(.down) * UsageIndex.slotSeconds
            return UsageSlot(slotStart: Date(timeIntervalSince1970: t), profileID: profile, model: model,
                             totals: TokenTotals(input: input, output: 1, cacheRead: 0, cacheCreation: 0, requests: 1))
        }
        let slots = [slot(3_600, a, "claude-opus-5-5", 100), slot(7_200, b, "claude-sonnet-4-5-20250929", 50),
                     slot(86_400 + 3_600, a, "claude-opus-5-5", 75)]
        let report = AnalyticsStore.makeReport(slots: slots, period: .day, start: start, end: end, profileFilter: nil, modelFilter: nil,
                                               names: [a: "Work"], calendar: calendar, coverageStart: end.addingTimeInterval(-3 * 86_400))
        #expect(report.current.input == 150)
        #expect(report.previous.input == 75)
        #expect(AnalyticsReport.change(report.current.input, report.previous.input) == 100)
        #expect(report.series.count >= 24 && report.series.count <= 25)
        #expect(report.series.reduce(Int64(0)) { $0 + $1.totals.input } == 150)
        // Buckets start on local hour boundaries (minute 0 in Kathmandu time).
        #expect(report.series.allSatisfy { calendar.component(.minute, from: $0.start) == 0 })
        #expect(report.byProfile.first?.label == "Work")
        #expect(report.byProfile.contains { $0.label == "Removed profile" })
        #expect(report.byModel.map(\.label) == ["Opus 5.5", "Sonnet 4.5"])
        #expect(!report.previousIsPartial)

        let filtered = AnalyticsStore.makeReport(slots: slots, period: .day, start: start, end: end, profileFilter: b, modelFilter: nil,
                                                 names: [:], calendar: calendar, coverageStart: nil)
        #expect(filtered.current.input == 50)
        #expect(filtered.previous.input == 0)
        #expect(AnalyticsReport.change(filtered.current.input, filtered.previous.input) == nil)
        #expect(filtered.previousIsPartial)
    }

    @Test func modelNames() {
        #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.display("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ModelName.display("claude-3-5-haiku-20241022") == "Haiku 3.5")
        #expect(ModelName.display("<weird>") == "<weird>")
        #expect(ModelName.display("claude-haiku-5-5") == "Haiku 5.5")
    }
}

