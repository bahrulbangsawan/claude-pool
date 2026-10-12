import Foundation

/// Every location the app reads or writes. Injected everywhere so tests use a temp root.
struct Paths: Sendable {
    let userHome: URL
    let appSupport: URL
    let caches: URL
    let pool: PoolPaths

    static func live() -> Paths {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Caches")
        return Paths(
            userHome: home,
            appSupport: support.appendingPathComponent("ClaudePool", isDirectory: true),
            caches: caches.appendingPathComponent("ClaudePool", isDirectory: true),
            pool: PoolPaths(home: home.appendingPathComponent(".claude-pool", isDirectory: true))
        )
    }

    /// A self-contained tree under `root`, for tests.
    static func temporary(root: URL) -> Paths {
        let home = root.appendingPathComponent("home", isDirectory: true)
        return Paths(
            userHome: home,
            appSupport: home.appendingPathComponent("Library/Application Support/ClaudePool", isDirectory: true),
            caches: home.appendingPathComponent("Library/Caches/ClaudePool", isDirectory: true),
            pool: PoolPaths(home: home.appendingPathComponent(".claude-pool", isDirectory: true))
        )
    }

    var profilesFile: URL { appSupport.appendingPathComponent("profiles.json") }
    var appSettingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    var defaultConfigDir: URL { userHome.appendingPathComponent(".claude", isDirectory: true) }

    /// Expands a leading `~` against the (injected) home directory.
    func expandTilde(_ path: String) -> String {
        if path == "~" { return userHome.path }
        if path.hasPrefix("~/") { return userHome.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }

    /// Shows `$HOME` as `~`.
    func abbreviate(_ path: String) -> String {
        let home = userHome.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Compares directories after resolving `.`/`..` and symlinks (e.g. /tmp vs /private/tmp).
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
