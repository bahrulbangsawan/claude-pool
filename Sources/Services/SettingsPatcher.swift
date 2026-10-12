import Foundation

enum TrackingState: Equatable, Sendable {
    case enabled
    case disabled
    /// Tracking is on in the app, but `statusLine` no longer points to the collector.
    case overridden

    var label: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .overridden: "Overridden externally"
        }
    }
}

enum SettingsPatcherError: Error, LocalizedError {
    case invalidJSON(String)
    case directoryMissing(String)
    case unreadable(String, String)

    var errorDescription: String? {
        switch self {
        case let .invalidJSON(path): "\(path) is not a valid JSON object. Nothing was changed."
        case let .directoryMissing(path): "The config directory \(path) does not exist."
        case let .unreadable(path, reason): "Could not read \(path): \(reason)"
        }
    }
}

/// Before/after `statusLine` values shown in the confirmation sheet.
struct StatusLinePreview: Equatable, Sendable {
    var before: String?
    var after: String?
}

/// Changes only the `statusLine` key of `<configDir>/settings.json`, with a backup before
/// every write. All other keys are preserved (their order may change).
struct SettingsPatcher: Sendable {
    static let maxBackups = 10
    static let confirmationText = "Claude Code will run this helper on every status line update. It reads only rate-limit fields and stores them on this Mac."

    enum EnableResult: Equatable, Sendable {
        case patched(originalStatusLine: String?)
        case alreadyEnabled
    }

    let pool: PoolPaths
    var clock: @Sendable () -> Date = { Date() }

    static func settingsURL(for profile: Profile) -> URL {
        profile.configURL.appendingPathComponent("settings.json")
    }

    static func collectorCommand(collectorPath: String, profileID: UUID) -> String {
        "\(ShellQuote.quote(collectorPath)) --profile \(profileID.uuidString)"
    }

    static func isCollector(_ value: Any?, profileID: UUID) -> Bool {
        guard let dict = value as? [String: Any],
              dict["type"] as? String == "command",
              let command = dict["command"] as? String else { return false }
        return command.contains(PoolPaths.collectorName)
            && command.lowercased().contains("--profile \(profileID.uuidString.lowercased())")
    }

    // MARK: Reading

    /// Reads only the `statusLine` value. Returns nil when the file or the key is missing.
    func currentStatusLine(for profile: Profile) throws -> Any? {
        try load(Self.settingsURL(for: profile)).object["statusLine"]
    }

    func state(for profile: Profile) -> TrackingState {
        let value = try? currentStatusLine(for: profile)
        if Self.isCollector(value ?? nil, profileID: profile.id) { return .enabled }
        return profile.trackingEnabled ? .overridden : .disabled
    }

    func previewEnable(_ profile: Profile, collectorPath: String) throws -> StatusLinePreview {
        let current = try currentStatusLine(for: profile)
        let next = Self.collectorValue(collectorPath: collectorPath, profileID: profile.id, carryingFrom: current)
        return StatusLinePreview(before: current.map(Self.prettyJSON), after: Self.prettyJSON(next))
    }

    func previewDisable(_ profile: Profile) throws -> StatusLinePreview {
        let current = try currentStatusLine(for: profile)
        guard Self.isCollector(current, profileID: profile.id) else {
            // Someone else's value is in place; disabling leaves it untouched.
            return StatusLinePreview(before: current.map(Self.prettyJSON), after: current.map(Self.prettyJSON))
        }
        let restored = profile.originalStatusLine.flatMap(Self.parseFragment)
        return StatusLinePreview(before: current.map(Self.prettyJSON), after: restored.map(Self.prettyJSON))
    }

    // MARK: Writing

    @discardableResult
    func enable(_ profile: Profile, collectorPath: String) throws -> EnableResult {
        let url = Self.settingsURL(for: profile)
        try requireDirectory(profile)
        var loaded = try load(url)
        let existing = loaded.object["statusLine"]
        if Self.isCollector(existing, profileID: profile.id) { return .alreadyEnabled }

        if let data = loaded.data { try backup(data, profileID: profile.id) }

        var original: String?
        let chainURL = pool.chainCommand(for: profile.id)
        if let existing {
            original = Self.compactJSON(existing)
            if let dict = existing as? [String: Any], dict["type"] as? String == "command",
               let command = dict["command"] as? String, !command.isEmpty {
                try AtomicFile.ensureDirectory(pool.chainDirectory, permissions: 0o700)
                try AtomicFile.write(Data(command.utf8), to: chainURL, permissions: 0o600)
            } else {
                try? FileManager.default.removeItem(at: chainURL)
            }
        } else {
            try? FileManager.default.removeItem(at: chainURL)
        }

        loaded.object["statusLine"] = Self.collectorValue(collectorPath: collectorPath, profileID: profile.id, carryingFrom: existing)
        try save(loaded, to: url)
        return .patched(originalStatusLine: original)
    }

    /// Restores the original value (or removes the key) when the collector is still in place.
    /// If the user replaced it since, their newer value is left alone.
    func disable(_ profile: Profile) throws {
        let url = Self.settingsURL(for: profile)
        let chainURL = pool.chainCommand(for: profile.id)
        guard FileManager.default.fileExists(atPath: profile.configDir) else {
            try? FileManager.default.removeItem(at: chainURL)
            return
        }
        var loaded = try load(url)
        if Self.isCollector(loaded.object["statusLine"], profileID: profile.id) {
            if let data = loaded.data { try backup(data, profileID: profile.id) }
            if let original = profile.originalStatusLine.flatMap(Self.parseFragment) {
                loaded.object["statusLine"] = original
            } else {
                loaded.object.removeValue(forKey: "statusLine")
            }
            try save(loaded, to: url)
        }
        try? FileManager.default.removeItem(at: chainURL)
    }

    // MARK: Status line manager support

    /// What currently renders this profile's status line, for the manager's integration list.
    enum CurrentStatusLine: Equatable, Sendable {
        case none
        case claudePool(refreshInterval: Int?)
        case ccstatusline(String)
        case other(String)
        case unreadable(String)
    }

    func describeCurrent(for profile: Profile) -> CurrentStatusLine {
        let value: Any?
        do { value = try currentStatusLine(for: profile) } catch { return .unreadable(error.localizedDescription) }
        guard let value else { return .none }
        if Self.isCollector(value, profileID: profile.id) {
            return .claudePool(refreshInterval: ((value as? [String: Any])?["refreshInterval"] as? NSNumber)?.intValue)
        }
        let command = ((value as? [String: Any])?["command"] as? String) ?? Self.compactJSON(value)
        if command.contains("ccstatusline") { return .ccstatusline(command) }
        return .other(command)
    }

    /// Sets `refreshInterval` (seconds, Claude Code ≥ 2.1.97) on Claude Pool's own status line value,
    /// so countdowns keep moving while idle. Changes nothing unless the collector is in place.
    func setRefreshInterval(_ seconds: Int?, for profile: Profile) throws {
        let url = Self.settingsURL(for: profile)
        var loaded = try load(url)
        guard var value = loaded.object["statusLine"] as? [String: Any], Self.isCollector(value, profileID: profile.id) else { return }
        let current = (value["refreshInterval"] as? NSNumber)?.intValue
        guard current != seconds else { return }
        if let data = loaded.data { try backup(data, profileID: profile.id) }
        if let seconds { value["refreshInterval"] = max(1, min(60, seconds)) } else { value.removeValue(forKey: "refreshInterval") }
        loaded.object["statusLine"] = value
        try save(loaded, to: url)
    }

    /// Backups of this profile's settings.json, newest first.
    func backups(for profileID: UUID) -> [URL] {
        let directory = pool.backups(for: profileID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("settings-") && $0.hasSuffix(".json") }.sorted().reversed()
            .map { directory.appendingPathComponent($0) }
    }

    /// The `statusLine` value stored in a backup (nil = the backup had none), for previews.
    func statusLine(inBackup url: URL) throws -> Any? {
        try load(url).object["statusLine"]
    }

    /// Restores only the `statusLine` key from a backup. Every other key keeps its current value.
    /// The current file is backed up first.
    func restoreStatusLine(fromBackup backupURL: URL, for profile: Profile) throws {
        let fromBackup = try load(backupURL).object["statusLine"]
        let url = Self.settingsURL(for: profile)
        try requireDirectory(profile)
        var loaded = try load(url)
        if let data = loaded.data { try backup(data, profileID: profile.id) }
        if let fromBackup { loaded.object["statusLine"] = fromBackup } else { loaded.object.removeValue(forKey: "statusLine") }
        try save(loaded, to: url)
    }

    // MARK: Helpers

    private struct Loaded {
        var object: [String: Any]
        var data: Data?
        var permissions: Int?
    }

    private func requireDirectory(_ profile: Profile) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: profile.configDir, isDirectory: &isDir), isDir.boolValue else {
            throw SettingsPatcherError.directoryMissing(profile.configDir)
        }
    }

    private func load(_ url: URL) throws -> Loaded {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return Loaded(object: [:]) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SettingsPatcherError.unreadable(url.path, error.localizedDescription)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SettingsPatcherError.invalidJSON(url.path)
        }
        let permissions = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        return Loaded(object: object, data: data, permissions: permissions)
    }

    private func save(_ loaded: Loaded, to url: URL) throws {
        var data = try JSONSerialization.data(
            withJSONObject: loaded.object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(UInt8(ascii: "\n"))
        try AtomicFile.write(data, to: url, permissions: mode_t((loaded.permissions ?? 0o600) & 0o7777))
    }

    /// Copies the original bytes to ~/.claude-pool/backups/<UUID>/ and keeps the newest 10.
    @discardableResult
    func backup(_ data: Data, profileID: UUID) throws -> URL {
        let directory = pool.backups(for: profileID)
        try AtomicFile.ensureDirectory(pool.backupsDirectory, permissions: 0o700)
        try AtomicFile.ensureDirectory(directory, permissions: 0o700)
        let stamp = Timestamp.string(clock())
        var url = directory.appendingPathComponent("settings-\(stamp).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("settings-\(stamp)_\(counter).json")
            counter += 1
        }
        try AtomicFile.write(data, to: url, permissions: 0o600)
        pruneBackups(in: directory)
        return url
    }

    private func pruneBackups(in directory: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let backups = names.filter { $0.hasPrefix("settings-") && $0.hasSuffix(".json") }.sorted()
        for name in backups.dropLast(Self.maxBackups) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func collectorValue(collectorPath: String, profileID: UUID, carryingFrom existing: Any?) -> [String: Any] {
        var value: [String: Any] = [
            "type": "command",
            "command": collectorCommand(collectorPath: collectorPath, profileID: profileID),
        ]
        if let padding = (existing as? [String: Any])?["padding"] { value["padding"] = padding }
        return value
    }

    static func compactJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func prettyJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseFragment(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }
}
