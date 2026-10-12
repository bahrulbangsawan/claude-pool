import Foundation
import Testing
@testable import ClaudePool

@MainActor
struct SessionTests {
    private func profile(_ temp: TempDirectory, _ name: String, isDefault: Bool = false) throws -> Profile {
        let dir = temp.file(".claude-\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Profile(id: UUID(), name: name, slug: name, configDir: dir.path, colorHex: "#0A84FF", isDefault: isDefault,
                       trackingEnabled: false, originalStatusLine: nil, sortIndex: 0, createdAt: Date())
    }

    private func register(_ profile: Profile, pid: Int32, session: String, cwd: String = "/Users/x/proj",
                          procStart: String? = nil, startedAt: Double = 1_791_000_000_000, status: String = "idle") throws {
        let dir = SessionRegistryService.directory(for: profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json = #"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"\#(cwd)","startedAt":\#(startedAt),"updatedAt":\#(startedAt + 5_000),"status":"\#(status)","version":"2.1.296","kind":"interactive","messagingSocketPath":"/tmp/SECRET-SOCKET""#
        if let procStart { json += #","procStart":"\#(procStart)""# }
        json += "}"
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(pid).json"))
    }

    @Test func procStartParsesPsFormatInUTC() {
        let date = SessionRegistryService.parseProcStart("Mon Oct 12 04:33:38 2026")
        #expect(date == Date(timeIntervalSince1970: 1_791_779_618))
        #expect(SessionRegistryService.parseProcStart("Thu Oct  8 07:21:31 2026") != nil)
        #expect(SessionRegistryService.parseProcStart("nonsense") == nil)
    }

    @Test func onlyLiveMatchingProcessesAreListed() throws {
        let temp = try TempDirectory()
        let work = try profile(temp, "work")
        let start = Date(timeIntervalSince1970: 1_791_779_618)
        let starts: [Int32: Date] = [100: start, 200: start.addingTimeInterval(500)]
        var registry = SessionRegistryService()
        registry.processStartTime = { starts[$0] }
        let id1 = UUID().uuidString, id2 = UUID().uuidString, id3 = UUID().uuidString
        try register(work, pid: 100, session: id1, procStart: "Mon Oct 12 04:33:38 2026")      // alive, same process
        try register(work, pid: 200, session: id2, procStart: "Mon Oct 12 04:33:38 2026")      // pid reused by another process
        try register(work, pid: 300, session: id3, procStart: "Mon Oct 12 04:33:38 2026")      // exited
        let sessions = registry.sessions(for: work)
        #expect(sessions.map(\.sessionID) == [id1])
        #expect(sessions.first?.profileID == work.id)
        #expect(!String(describing: sessions).contains("SECRET-SOCKET"))
    }

    @Test func handoffCopiesConversationWithoutOverwriting() throws {
        let temp = try TempDirectory()
        let source = try profile(temp, "a"), target = try profile(temp, "b")
        let sessionID = UUID().uuidString
        let projectKey = "-Users-x-proj"
        let sourceDir = source.configURL.appendingPathComponent("projects/\(projectKey)")
        try FileManager.default.createDirectory(at: sourceDir.appendingPathComponent("\(sessionID)/subagents"), withIntermediateDirectories: true)
        // Last line is still being written (no newline): it must not be copied half-way.
        try Data("line1\nline2\npartial".utf8).write(to: sourceDir.appendingPathComponent("\(sessionID).jsonl"))
        try Data("sub\n".utf8).write(to: sourceDir.appendingPathComponent("\(sessionID)/subagents/agent-1.jsonl"))
        let existing = target.configURL.appendingPathComponent("projects/\(projectKey)")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("older copy\n".utf8).write(to: existing.appendingPathComponent("\(sessionID).jsonl"))

        let session = ClaudeSession(profileID: source.id, pid: 1, sessionID: sessionID, cwd: "/Users/x/proj", name: nil,
                                    startedAt: nil, updatedAt: nil, status: "idle", version: nil, kind: nil)
        let service = SessionHandoffService(clock: { Date(timeIntervalSince1970: 1_791_000_000) })
        let plan = try service.plan(session, from: source, to: target)
        let result = try service.execute(plan)

        #expect(readText(plan.destinationTranscript) == "line1\nline2\n")
        #expect(readText(existing.appendingPathComponent("\(sessionID)/subagents/agent-1.jsonl")) == "sub\n")
        #expect(result.backups.count == 1)
        #expect(result.backups.first.flatMap(readText) == "older copy\n")
        #expect(result.copiedFiles.count == 2)
        #expect(permissions(of: plan.destinationTranscript) == 0o600)
        // The source is untouched.
        #expect(readText(sourceDir.appendingPathComponent("\(sessionID).jsonl")) == "line1\nline2\npartial")
    }

    @Test func handoffRejectsUnsafeOrMissingInput() throws {
        let temp = try TempDirectory()
        let source = try profile(temp, "a"), target = try profile(temp, "b")
        let service = SessionHandoffService()
        func session(_ id: String) -> ClaudeSession {
            ClaudeSession(profileID: source.id, pid: 1, sessionID: id, cwd: "/", name: nil, startedAt: nil, updatedAt: nil, status: nil, version: nil, kind: nil)
        }
        #expect(throws: SessionHandoffError.invalidSessionID) { try service.plan(session("../../etc/passwd"), from: source, to: target) }
        #expect(throws: SessionHandoffError.sameProfile) { try service.plan(session(UUID().uuidString), from: source, to: source) }
        #expect(throws: SessionHandoffError.transcriptNotFound(source.configDir)) { try service.plan(session(UUID().uuidString), from: source, to: target) }
    }

    @Test func handoffIsConfirmedOnlyWhenTheTargetRegistersTheSession() throws {
        let temp = try TempDirectory()
        let source = try profile(temp, "a"), target = try profile(temp, "b")
        let base = Date(timeIntervalSince1970: 1_791_779_618)
        var live: [Int32: Date] = [10: base]
        let box = StartTimes(live)
        var registry = SessionRegistryService()
        registry.processStartTime = { box.get($0) }
        let store = SessionStore(registry: registry)
        store.start(profiles: { [source, target] })
        store.stop()
        let sessionID = UUID().uuidString
        try register(source, pid: 10, session: sessionID, procStart: "Mon Oct 12 04:33:38 2026")
        store.refresh(now: base)
        let session = try #require(store.sessions.first)
        #expect(store.sessions(notOn: target.id).count == 1)

        store.beginHandoff(session, to: target.id, now: base.addingTimeInterval(10))
        #expect(store.handoff(for: session)?.state == .pending)

        // Still pending while only the old process exists.
        store.refresh(now: base.addingTimeInterval(20))
        #expect(store.handoff(for: session)?.state == .pending)

        // Claude Code registers the resumed session under the target directory.
        live[20] = base.addingTimeInterval(15)
        box.set(live)
        try register(target, pid: 20, session: sessionID, procStart: "Mon Oct 12 04:33:53 2026", startedAt: (base.timeIntervalSince1970 + 15) * 1000)
        store.refresh(now: base.addingTimeInterval(25))
        #expect(store.handoff(for: session)?.state == .confirmed(pid: 20))
    }

    @Test func unconfirmedHandoffTimesOut() throws {
        let temp = try TempDirectory()
        let source = try profile(temp, "a"), target = try profile(temp, "b")
        let base = Date(timeIntervalSince1970: 1_791_779_618)
        var registry = SessionRegistryService()
        registry.processStartTime = { $0 == 10 ? base : nil }
        let store = SessionStore(registry: registry)
        store.start(profiles: { [source, target] })
        store.stop()
        try register(source, pid: 10, session: UUID().uuidString, procStart: "Mon Oct 12 04:33:38 2026")
        store.refresh(now: base)
        let session = try #require(store.sessions.first)
        store.beginHandoff(session, to: target.id, now: base)
        store.refresh(now: base.addingTimeInterval(SessionStore.confirmationTimeout + 1))
        #expect(store.handoff(for: session)?.state == .unconfirmed)
    }
}

private final class StartTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32: Date]
    init(_ values: [Int32: Date]) { self.values = values }
    func get(_ pid: Int32) -> Date? { lock.withLock { values[pid] } }
    func set(_ new: [Int32: Date]) { lock.withLock { values = new } }
}
