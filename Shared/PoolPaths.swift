import Foundation

/// Locations under the app home (`~/.claude-pool`). Shared by the app and the collector.
///
/// Every path is derived from `home` so tests can point the whole tree at a temporary
/// directory. `CLAUDE_POOL_HOME` overrides the location for the collector subprocess tests.
public struct PoolPaths: Sendable, Hashable {
    public static let homeOverrideVariable = "CLAUDE_POOL_HOME"
    public static let collectorName = "claude-pool-collector"

    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    /// Resolves `~/.claude-pool`, honouring `CLAUDE_POOL_HOME` when it holds an absolute path.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PoolPaths {
        if let override = environment[homeOverrideVariable], override.hasPrefix("/") {
            return PoolPaths(home: URL(fileURLWithPath: override, isDirectory: true))
        }
        return PoolPaths(home: userHome.appendingPathComponent(".claude-pool", isDirectory: true))
    }

    /// Absolute config directory of the active non-default profile; empty file = Default.
    public var activePointer: URL { home.appendingPathComponent("active") }
    public var binDirectory: URL { home.appendingPathComponent("bin", isDirectory: true) }
    public var installedCollector: URL { binDirectory.appendingPathComponent(Self.collectorName) }
    public var usageDirectory: URL { home.appendingPathComponent("usage", isDirectory: true) }
    public var chainDirectory: URL { home.appendingPathComponent("chain", isDirectory: true) }
    public var backupsDirectory: URL { home.appendingPathComponent("backups", isDirectory: true) }
    /// Which shared extensions each profile held at the last sync (for spreading deletions).
    public var sharedSyncState: URL { home.appendingPathComponent("shared-sync-state.json") }
    /// Config directory → profile, for the collector (see `ProfileDirectories`).
    public var profileDirectories: URL { home.appendingPathComponent("profile-dirs.json") }
    public var sharedSyncBackups: URL { backupsDirectory.appendingPathComponent("shared-sync", isDirectory: true) }
    /// One word, `summary` or `none`: what the collector prints when no original status line exists.
    public var collectorOutputSetting: URL { home.appendingPathComponent("collector-output") }

    /// Status line manager: the applied layout, per-profile state and the apply history.
    public var statuslineDirectory: URL { home.appendingPathComponent("statusline", isDirectory: true) }
    public var statuslineConfig: URL { statuslineDirectory.appendingPathComponent("config.json") }
    public var statuslineHistoryDirectory: URL { statuslineDirectory.appendingPathComponent("history", isDirectory: true) }

    public func statuslineProfile(for profileID: UUID) -> URL {
        statuslineDirectory.appendingPathComponent("profile-\(profileID.uuidString).json")
    }

    public func snapshot(for profileID: UUID) -> URL {
        usageDirectory.appendingPathComponent("\(profileID.uuidString).json")
    }

    public func history(for profileID: UUID) -> URL {
        usageDirectory.appendingPathComponent("\(profileID.uuidString).history.jsonl")
    }

    /// What each open claude session last reported, keyed by a hash (see `ReporterLog`).
    public func reporters(for profileID: UUID) -> URL {
        usageDirectory.appendingPathComponent("\(profileID.uuidString).reporters.json")
    }

    public func chainCommand(for profileID: UUID) -> URL {
        chainDirectory.appendingPathComponent("\(profileID.uuidString).cmd")
    }

    public func backups(for profileID: UUID) -> URL {
        backupsDirectory.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }
}

/// What the collector prints when the profile had no status line of its own.
public enum CollectorOutputMode: String, Codable, Sendable, CaseIterable {
    case summary
    case none
}
