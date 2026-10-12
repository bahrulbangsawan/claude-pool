import Foundation

/// `~/.claude-pool/active`: the config dir of the active non-default profile. Empty = Default.
struct PointerFileService: Sendable {
    let pool: PoolPaths

    var url: URL { pool.activePointer }

    /// nil means Default (missing or empty file).
    func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Writes the directory with no trailing newline, or empties the file for Default.
    func write(_ configDir: String?) throws {
        try AtomicFile.ensureDirectory(pool.home, permissions: 0o700)
        try AtomicFile.write(Data((configDir ?? "").utf8), to: url, permissions: 0o600)
    }

    func setActive(_ profile: Profile) throws {
        try write(profile.configDirEnvironmentValue)
    }
}
