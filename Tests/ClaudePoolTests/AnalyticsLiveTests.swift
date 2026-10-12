import Foundation
import Testing
@testable import ClaudePool

/// Indexes your REAL conversation files into a temporary index (your files are only read) and
/// prints totals for comparison with an independent computation. Run with `make live-check`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLAUDE_POOL_LIVE"] == "1"))
struct AnalyticsLiveTests {
    @Test func indexesRealConversationFiles() async throws {
        let temp = try TempDirectory()
        let paths = Paths.live()
        let data = try? Data(contentsOf: paths.profilesFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profiles = (data.flatMap { try? decoder.decode([Profile].self, from: $0) }) ?? [Profile.makeDefault(home: paths.userHome)]
        let index = try UsageIndex(url: temp.file("live.sqlite"))
        let now = Date()
        let started = Date()
        let report = try await index.scan(profiles: profiles.map { ($0.id, $0.configURL.appendingPathComponent("projects")) }, now: now)
        let elapsed = Date().timeIntervalSince(started)
        print("LIVE analytics: \(report.filesScanned) files, \(report.bytesRead / 1_000_000) MB, \(report.linesRead) lines, \(report.requestsAdded) requests in \(String(format: "%.1f", elapsed))s")
        for profile in profiles {
            for days in [1.0, 7, 30] {
                let t = try await index.totals(from: now.addingTimeInterval(-days * 86_400), to: now, profiles: [profile.id])
                print("LIVE analytics \(profile.slug) \(Int(days))d: requests=\(t.requests) input=\(t.input) output=\(t.output) cacheRead=\(t.cacheRead) cacheWrite=\(t.cacheCreation) cutoff=\(Int(now.timeIntervalSince1970))")
            }
        }
        let again = Date()
        let second = try await index.scan(profiles: profiles.map { ($0.id, $0.configURL.appendingPathComponent("projects")) }, now: Date())
        print("LIVE analytics incremental rescan: \(second.filesScanned) files, \(second.requestsAdded) new requests in \(String(format: "%.2f", Date().timeIntervalSince(again)))s")
        #expect(report.requestsAdded > 0)
    }
}
