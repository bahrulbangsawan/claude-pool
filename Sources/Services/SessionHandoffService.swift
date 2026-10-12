import Foundation

enum SessionHandoffError: Error, LocalizedError, Equatable {
    case sameProfile
    case invalidSessionID
    case transcriptNotFound(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .sameProfile:
            "The session already runs on this profile."
        case .invalidSessionID:
            "The session ID reported by Claude Code isn't a valid UUID, so it can't be resumed safely."
        case let .transcriptNotFound(dir):
            "Couldn't find this session's conversation file under \(dir)/projects. It may not have saved a message yet; send one, then try again."
        case let .copyFailed(reason):
            "Couldn't copy the conversation to the other profile: \(reason). Nothing was launched."
        }
    }
}

/// Moves a conversation to another profile without touching credentials: the conversation file is
/// copied into the target profile's directory, then a new `claude --resume <id>` is started there
/// with the target's `CLAUDE_CONFIG_DIR`. The original process is never signalled or redirected.
///
/// Claude Code stores conversations as `<configDir>/projects/<project-key>/<sessionID>.jsonl`, plus
/// an optional `<sessionID>/` folder (subagents, tool results). The app copies those bytes as-is
/// and never parses them.
struct SessionHandoffService: Sendable {
    struct Plan: Hashable, Sendable {
        let session: ClaudeSession
        let source: Profile
        let target: Profile
        let transcript: URL
        let companion: URL?
        let destinationDirectory: URL

        var destinationTranscript: URL { destinationDirectory.appendingPathComponent(transcript.lastPathComponent) }
        var destinationCompanion: URL? { companion.map { destinationDirectory.appendingPathComponent($0.lastPathComponent, isDirectory: true) } }
    }

    struct Result: Sendable {
        /// Every conversation file now in the target profile with the size it had when copied, so
        /// usage analytics counts only what is appended afterwards (no double counting).
        var copiedFiles: [(url: URL, size: Int64)]
        /// Anything that was in the way, renamed rather than overwritten.
        var backups: [URL]
    }

    var clock: @Sendable () -> Date = { Date() }

    static func isValidSessionID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    func plan(_ session: ClaudeSession, from source: Profile, to target: Profile) throws -> Plan {
        guard source.id != target.id else { throw SessionHandoffError.sameProfile }
        guard Self.isValidSessionID(session.sessionID) else { throw SessionHandoffError.invalidSessionID }
        let projects = source.configURL.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        let fileName = "\(session.sessionID).jsonl"
        // The project key is derived from the cwd by Claude Code; look it up rather than re-deriving it.
        let keys = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        var found: URL?
        var newest = Date.distantPast
        for key in keys where !key.hasPrefix(".") {
            let candidate = projects.appendingPathComponent(key, isDirectory: true).appendingPathComponent(fileName)
            guard let attributes = try? fm.attributesOfItem(atPath: candidate.path) else { continue }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            if modified >= newest { found = candidate; newest = modified }
        }
        guard let transcript = found else { throw SessionHandoffError.transcriptNotFound(source.configDir) }
        let projectDir = transcript.deletingLastPathComponent()
        let companionURL = projectDir.appendingPathComponent(session.sessionID, isDirectory: true)
        var isDir: ObjCBool = false
        let companion = fm.fileExists(atPath: companionURL.path, isDirectory: &isDir) && isDir.boolValue ? companionURL : nil
        let destination = target.configURL
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDir.lastPathComponent, isDirectory: true)
        return Plan(session: session, source: source, target: target, transcript: transcript, companion: companion, destinationDirectory: destination)
    }

    /// Copies the conversation. Existing copies in the target are renamed, never overwritten.
    func execute(_ plan: Plan) throws -> Result {
        let fm = FileManager.default
        let stamp = Timestamp.string(clock())
        var backups: [URL] = []
        do {
            try AtomicFile.ensureDirectory(plan.target.configURL.appendingPathComponent("projects", isDirectory: true), permissions: 0o700)
            try AtomicFile.ensureDirectory(plan.destinationDirectory, permissions: 0o700)

            if let companion = plan.companion, let destination = plan.destinationCompanion {
                let staging = plan.destinationDirectory.appendingPathComponent(".\(plan.session.sessionID).\(UUID().uuidString).tmp", isDirectory: true)
                try fm.copyItem(at: companion, to: staging)
                if fm.fileExists(atPath: destination.path) {
                    let backup = plan.destinationDirectory.appendingPathComponent("\(plan.session.sessionID).claude-pool-bak-\(stamp)", isDirectory: true)
                    try fm.moveItem(at: destination, to: backup)
                    backups.append(backup)
                }
                try fm.moveItem(at: staging, to: destination)
            }

            // Read the source once and write it whole, so a line being appended right now is either
            // fully in the copy or not at all; a trailing partial line is dropped.
            var data = try Data(contentsOf: plan.transcript)
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")), lastNewline < data.index(before: data.endIndex) {
                data = data.prefix(through: lastNewline)
            }
            if fm.fileExists(atPath: plan.destinationTranscript.path) {
                let backup = plan.destinationDirectory.appendingPathComponent("\(plan.session.sessionID).jsonl.claude-pool-bak-\(stamp)")
                try fm.moveItem(at: plan.destinationTranscript, to: backup)
                backups.append(backup)
            }
            try AtomicFile.write(data, to: plan.destinationTranscript, permissions: 0o600)
        } catch let error as SessionHandoffError {
            throw error
        } catch {
            throw SessionHandoffError.copyFailed(error.localizedDescription)
        }

        var copied: [(URL, Int64)] = [(plan.destinationTranscript, Self.size(of: plan.destinationTranscript))]
        if let destination = plan.destinationCompanion {
            copied += Self.jsonlFiles(under: destination).map { ($0, Self.size(of: $0)) }
        }
        return Result(copiedFiles: copied, backups: backups)
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func jsonlFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }
}
