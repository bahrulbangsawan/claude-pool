import Foundation

/// Which profile owns which Claude Code config directory. The app writes it to
/// `~/.claude-pool/profile-dirs.json`; the collector reads it to file each report under the profile
/// the session really belongs to.
///
/// A session started in the home folder also loads `~/.claude/settings.json` as project settings,
/// so another profile's session runs the Default profile's status line command (and its
/// `--profile`). The session's own `CLAUDE_CONFIG_DIR`, unset for Default, says which profile it is.
public struct ProfileDirectories: Codable, Equatable, Sendable {
    public var schema = 1
    public var defaultProfile: UUID?
    /// Canonical config directory → profile, for every profile.
    public var directories: [String: UUID]

    public init(defaultProfile: UUID?, directories: [String: UUID]) {
        self.defaultProfile = defaultProfile
        self.directories = directories
    }

    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The profile a session with this `CLAUDE_CONFIG_DIR` belongs to, or nil when no profile has it.
    public func profile(forConfigDir configDir: String?) -> UUID? {
        guard let configDir, !configDir.isEmpty else { return defaultProfile }
        return directories[Self.canonical(configDir)]
    }

    public static func load(_ url: URL) -> ProfileDirectories? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProfileDirectories.self, from: data)
    }
}
