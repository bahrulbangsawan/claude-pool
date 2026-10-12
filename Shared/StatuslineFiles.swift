import Foundation

/// Per-profile status line state written by the app and read by the collector on every run.
/// Changing it never touches `settings.json`, so it takes effect on Claude Code's next refresh.
public struct StatuslineProfileState: Codable, Hashable, Sendable {
    /// True: render Claude Pool's layout. False: original status line or summary, as before.
    public var managed: Bool
    /// Display-only values for the Account, Plan and Profile components. Never secrets.
    public var profileName: String?
    public var account: String?
    public var plan: String?

    public init(managed: Bool, profileName: String? = nil, account: String? = nil, plan: String? = nil) {
        self.managed = managed
        self.profileName = profileName
        self.account = account
        self.plan = plan
    }
}

public enum StatuslineFiles {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The applied layout, or nil if missing or not valid (the collector then falls back).
    public static func loadConfig(_ paths: PoolPaths) -> StatuslineConfig? {
        guard let data = try? Data(contentsOf: paths.statuslineConfig),
              let config = try? JSONDecoder().decode(StatuslineConfig.self, from: data),
              config.isValid else { return nil }
        return config
    }

    public static func loadProfile(_ paths: PoolPaths, id: UUID) -> StatuslineProfileState? {
        guard let data = try? Data(contentsOf: paths.statuslineProfile(for: id)) else { return nil }
        return try? JSONDecoder().decode(StatuslineProfileState.self, from: data)
    }

    public static func writeConfig(_ config: StatuslineConfig, _ paths: PoolPaths) throws {
        try AtomicFile.ensureDirectory(paths.home, permissions: 0o700)
        try AtomicFile.ensureDirectory(paths.statuslineDirectory, permissions: 0o700)
        try AtomicFile.write(try encoder().encode(config), to: paths.statuslineConfig, permissions: 0o600)
    }

    public static func writeProfile(_ state: StatuslineProfileState, id: UUID, _ paths: PoolPaths) throws {
        try AtomicFile.ensureDirectory(paths.home, permissions: 0o700)
        try AtomicFile.ensureDirectory(paths.statuslineDirectory, permissions: 0o700)
        try AtomicFile.write(try encoder().encode(state), to: paths.statuslineProfile(for: id), permissions: 0o600)
    }
}
