import Foundation

/// Keeps user-scope Claude Code extensions the same in every profile, so switching accounts
/// never loses an MCP server, skill or plugin.
///
/// Shared: MCP servers (user scope), skills, agents, commands, output styles, CLAUDE.md,
/// enabled plugins and extra marketplaces, hooks and permission rules. Plugin installs
/// (`plugins/installed_plugins.json`, caches) stay per profile: Claude Code installs every
/// enabled plugin into the profile's own cache, and syncing install records would fight it.
/// Left per account: sign-in, statusLine, theme, model and everything else, plus the
/// skills and plugins claude.ai syncs for an organisation (`synced/`).
///
/// The Default profile holds the primary copy. Skill-like entries live there and other profiles
/// get symlinks; anything created inside another profile is moved to the primary and linked back.
/// Keyed values are merged three ways: additions in any profile spread to all, and removing an
/// entry that a profile held at the previous sync removes it everywhere.
struct SharedConfigSync: Sendable {
    static let linkedDirectories = ["skills", "agents", "commands", "output-styles"]
    static let linkedFiles = ["CLAUDE.md"]
    /// claude.ai organisation buckets, which belong to one account.
    static let skippedEntries: Set<String> = ["synced"]
    static let maxBackups = 10

    struct Report: Equatable, Sendable {
        var changes: [String] = []
    }

    let pool: PoolPaths
    let home: URL
    var clock: @Sendable () -> Date = { Date() }

    private struct Target {
        let dir: URL
        let globalConfig: URL
        var key: String { dir.path }
        var settings: URL { dir.appendingPathComponent("settings.json") }
    }

    /// A keyed collection inside one JSON file, with ordered keys.
    private struct Category {
        let name: String
        let get: ([String: Any]) -> [(String, Any)]
        let set: (inout [String: Any], [(String, Any)]) -> Void
    }

    func run(profiles: [Profile]) throws -> Report {
        let targets = profiles
            .sorted { $0.isDefault && !$1.isDefault }
            .filter { FileManager.default.fileExists(atPath: $0.configDir) }
            .map { Target(dir: URL(fileURLWithPath: Paths.canonical($0.configDir), isDirectory: true),
                          globalConfig: AccountDetailsReader.configFile(for: $0, home: home)) }
        guard targets.count > 1, profiles.first(where: \.isDefault).map({ FileManager.default.fileExists(atPath: $0.configDir) }) == true else {
            return Report()
        }
        var session = Session(pool: pool, stamp: Self.stamp(clock()))
        let primary = targets[0], others = Array(targets.dropFirst())
        for name in Self.linkedDirectories { try session.linkEntries(name, primary: primary.dir, others: others.map(\.dir)) }
        for name in Self.linkedFiles { try session.linkFile(name, primary: primary.dir, others: others.map(\.dir)) }

        var state = Self.readState(pool.sharedSyncState)
        try session.syncFile(targets.map(\.globalConfig), keys: targets.map(\.key), state: &state, categories: [
            Self.dictCategory("mcpServers"),
        ])
        try session.syncFile(targets.map(\.settings), keys: targets.map(\.key), state: &state, categories: [
            Self.dictCategory("enabledPlugins"),
            Self.dictCategory("extraKnownMarketplaces"),
            Self.hooksCategory,
        ] + ["allow", "deny", "ask"].map(Self.permissionCategory))
        // Forget profiles that no longer exist.
        let live = Set(targets.map(\.key))
        state = state.filter { live.contains($0.key) }
        try Self.writeJSON(state, to: pool.sharedSyncState, permissions: 0o600)
        session.pruneBackups()
        return Report(changes: session.changes)
    }

    // MARK: Categories

    private static func ordered(_ dict: [String: Any]?) -> [(String, Any)] {
        (dict ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private static func dictCategory(_ key: String) -> Category {
        Category(name: key, get: { ordered($0[key] as? [String: Any]) }, set: { object, merged in
            if merged.isEmpty { object.removeValue(forKey: key) }
            else { object[key] = Dictionary(merged, uniquingKeysWith: { a, _ in a }) }
        })
    }

    private static var hooksCategory: Category { Category(name: "hooks", get: { object in
        guard let hooks = object["hooks"] as? [String: Any] else { return [] }
        return hooks.keys.sorted().flatMap { event in
            ((hooks[event] as? [Any]) ?? []).map { group in ("\(event)\u{0}\(canonicalJSON(group))", group) }
        }
    }, set: { object, merged in
        guard !merged.isEmpty else { object.removeValue(forKey: "hooks"); return }
        var hooks: [String: [Any]] = [:]
        for (key, group) in merged {
            hooks[String(key.prefix { $0 != "\u{0}" }), default: []].append(group)
        }
        object["hooks"] = hooks
    }) }

    private static func permissionCategory(_ kind: String) -> Category {
        Category(name: "permissions.\(kind)", get: { object in
            (((object["permissions"] as? [String: Any])?[kind] as? [Any]) ?? []).compactMap { $0 as? String }.map { ($0, true) }
        }, set: { object, merged in
            var permissions = (object["permissions"] as? [String: Any]) ?? [:]
            if merged.isEmpty { permissions.removeValue(forKey: kind) } else { permissions[kind] = merged.map(\.0) }
            if permissions.isEmpty { object.removeValue(forKey: "permissions") } else { object["permissions"] = permissions }
        })
    }

    private static func canonicalJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: State and JSON

    /// profile directory → category → keys that profile held at the last sync.
    private typealias State = [String: [String: [String]]]

    private static func readState(_ url: URL) -> State {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: [String: [String]]] else { return [:] }
        return state
    }

    fileprivate static func readObject(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsPatcherError.invalidJSON(url.path)
        }
        return object
    }

    fileprivate static func writeJSON(_ object: Any, to url: URL, permissions: mode_t) throws {
        try AtomicFile.ensureDirectory(url.deletingLastPathComponent(), permissions: 0o755)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try AtomicFile.write(data, to: url, permissions: permissions)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: Session

    /// One run: collects the change log and backs up each file once before its first write.
    private struct Session {
        let pool: PoolPaths
        let stamp: String
        var changes: [String] = []
        let fm = FileManager.default

        var backupDirectory: URL { pool.sharedSyncBackups.appendingPathComponent(stamp, isDirectory: true) }

        mutating func log(_ message: String) { changes.append(message) }

        func lexists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
        func isSymlink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }

        func entries(_ dir: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") && !SharedConfigSync.skippedEntries.contains($0) }
                .sorted()
        }

        mutating func linkEntries(_ name: String, primary: URL, others: [URL]) throws {
            let source = primary.appendingPathComponent(name, isDirectory: true)
            let targets = others.map { $0.appendingPathComponent(name, isDirectory: true) }.filter { !isSymlink($0) }
            for dir in targets {
                for entry in entries(dir) {
                    let path = dir.appendingPathComponent(entry)
                    if let destination = try? fm.destinationOfSymbolicLink(atPath: path.path) {
                        // A link we made whose primary entry was removed: remove it too.
                        if !fm.fileExists(atPath: path.path), destination.hasPrefix(source.path + "/") {
                            try fm.removeItem(at: path)
                            log("Removed \(entry) from \(dir.path)")
                        }
                        continue
                    }
                    let destination = source.appendingPathComponent(entry)
                    guard !lexists(destination) else { continue }  // a local copy that shadows the primary's
                    try AtomicFile.ensureDirectory(source, permissions: 0o755)
                    try fm.moveItem(at: path, to: destination)
                    try fm.createSymbolicLink(at: path, withDestinationURL: destination)
                    log("Shared \(entry) from \(dir.path)")
                }
            }
            for entry in entries(source) {
                let destination = source.appendingPathComponent(entry)
                guard fm.fileExists(atPath: destination.path) else { continue }  // broken in the primary too
                for dir in targets {
                    let path = dir.appendingPathComponent(entry)
                    guard !lexists(path) else { continue }
                    try AtomicFile.ensureDirectory(dir, permissions: 0o755)
                    try fm.createSymbolicLink(at: path, withDestinationURL: destination)
                    log("Linked \(name)/\(entry) into \(dir.path)")
                }
            }
        }

        mutating func linkFile(_ name: String, primary: URL, others: [URL]) throws {
            let source = primary.appendingPathComponent(name)
            if !lexists(source), let local = others.map({ $0.appendingPathComponent(name) }).first(where: { fm.fileExists(atPath: $0.path) && !isSymlink($0) }) {
                try fm.moveItem(at: local, to: source)
                try fm.createSymbolicLink(at: local, withDestinationURL: source)
                log("Shared \(name) from \(local.deletingLastPathComponent().path)")
            }
            guard fm.fileExists(atPath: source.path) else { return }
            for dir in others where !lexists(dir.appendingPathComponent(name)) {
                try fm.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: source)
                log("Linked \(name) into \(dir.path)")
            }
        }

        mutating func syncFile(_ files: [URL], keys: [String], state: inout State, categories: [Category]) throws {
            // A file that isn't valid JSON is left alone, and so is the whole set: merging without it could
            // read its entries as deleted.
            let originals = try files.map(SharedConfigSync.readObject)
            var objects = originals.map { $0 ?? [:] }
            for category in categories {
                let current = objects.map(category.get)
                var deleted = Set<String>()
                for (index, values) in current.enumerated() {
                    guard let previous = state[keys[index]]?[category.name] else { continue }
                    deleted.formUnion(Set(previous).subtracting(values.map(\.0)))
                }
                var merged: [(String, Any)] = []
                var seen = Set<String>()
                for values in current {
                    for (key, value) in values where !seen.contains(key) {
                        seen.insert(key)
                        merged.append((key, value))
                    }
                }
                for key in deleted where seen.contains(key) {
                    log("Removed \(Self.label(key)) (\(category.name)) from every profile")
                }
                merged.removeAll { deleted.contains($0.0) }
                let kept = Set(merged.map(\.0))
                for (index, values) in current.enumerated() {
                    let held = Set(values.map(\.0))
                    let added = merged.map(\.0).filter { !held.contains($0) }
                    if !added.isEmpty {
                        log("Added \(added.map(Self.label).joined(separator: ", ")) (\(category.name)) to \(files[index].deletingLastPathComponent().path)")
                    }
                    category.set(&objects[index], merged)
                    // Only what was on disk counts as held: an entry written now is confirmed by the next run,
                    // so a stale write by a running session can't be mistaken for a deletion.
                    state[keys[index], default: [:]][category.name] = values.map(\.0).filter { kept.contains($0) }
                }
            }
            for (index, object) in objects.enumerated() where !NSDictionary(dictionary: object).isEqual(to: originals[index] ?? [:]) {
                let file = files[index]
                let mode = ((try? fm.attributesOfItem(atPath: file.path)[.posixPermissions]) as? NSNumber).map { mode_t($0.uint16Value) } ?? 0o600
                if originals[index] != nil { try backUp(file) }
                try SharedConfigSync.writeJSON(object, to: file, permissions: mode)
            }
        }

        private static func label(_ key: String) -> String {
            String(key.prefix { $0 != "\u{0}" })
        }

        private func backUp(_ file: URL) throws {
            try AtomicFile.ensureDirectory(backupDirectory, permissions: 0o700)
            let name = file.path.replacingOccurrences(of: "/", with: "_")
            let destination = backupDirectory.appendingPathComponent(name)
            if !lexists(destination) { try fm.copyItem(at: file, to: destination) }
        }

        func pruneBackups() {
            let runs = entries(pool.sharedSyncBackups)
            for name in runs.dropLast(SharedConfigSync.maxBackups) {
                try? fm.removeItem(at: pool.sharedSyncBackups.appendingPathComponent(name))
            }
        }
    }
}
