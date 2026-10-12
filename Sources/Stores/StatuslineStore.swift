import Foundation
import Observation

struct StatuslinePreset: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var config: StatuslineConfig
    var createdAt: Date
}

enum StatuslineStoreError: Error, LocalizedError {
    case invalid([String])
    case nothingToUndo
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(errors): "The layout can't be applied: \(errors.joined(separator: " "))"
        case .nothingToUndo: "There is no earlier applied layout to go back to."
        case let .importFailed(reason): "Couldn't import that file: \(reason)"
        }
    }
}

/// The status line layout being edited (draft), the one in effect (applied), saved presets, and
/// which profiles render it. Applying writes `~/.claude-pool/statusline/config.json` atomically and
/// keeps the previous layout in `history/` so it can be restored.
@MainActor
@Observable
final class StatuslineStore {
    static let maxHistory = 10

    var draft: StatuslineConfig
    private(set) var applied: StatuslineConfig?
    private(set) var presets: [StatuslinePreset] = []
    private(set) var profileStates: [UUID: StatuslineProfileState] = [:]
    private(set) var historyCount = 0
    private(set) var lastAppliedAt: Date?

    let pool: PoolPaths
    let presetsFile: URL
    @ObservationIgnored var clock: () -> Date = Date.init

    init(pool: PoolPaths, presetsFile: URL) {
        self.pool = pool
        self.presetsFile = presetsFile
        draft = StatuslinePresets.essentials
    }

    var hasUnappliedChanges: Bool { applied.map { $0 != draft } ?? true }

    func load(profiles: [Profile]) {
        applied = StatuslineFiles.loadConfig(pool)
        if let applied { draft = applied }
        lastAppliedAt = (try? FileManager.default.attributesOfItem(atPath: pool.statuslineConfig.path))?[.modificationDate] as? Date
        if let data = try? Data(contentsOf: presetsFile), let decoded = try? ProfileStore.decoder.decode([StatuslinePreset].self, from: data) {
            presets = decoded
        }
        var states: [UUID: StatuslineProfileState] = [:]
        for profile in profiles {
            if let state = StatuslineFiles.loadProfile(pool, id: profile.id) { states[profile.id] = state }
        }
        profileStates = states
        historyCount = historyFiles().count
    }

    func isManaged(_ id: UUID) -> Bool { profileStates[id]?.managed == true }

    // MARK: Apply / revert

    func apply() throws {
        let errors = draft.validationErrors()
        guard errors.isEmpty else { throw StatuslineStoreError.invalid(errors) }
        if let applied, applied != draft { try archive(applied) }
        try StatuslineFiles.writeConfig(draft, pool)
        // Read back what the collector will read, so the UI never claims a layout that isn't on disk.
        applied = StatuslineFiles.loadConfig(pool)
        lastAppliedAt = clock()
        historyCount = historyFiles().count
    }

    /// Discards edits that were not applied.
    func revertDraft() {
        draft = applied ?? StatuslinePresets.essentials
    }

    func restoreDefaults() {
        draft = StatuslinePresets.essentials
    }

    /// Puts the previously applied layout back in effect.
    func undoLastApply() throws {
        guard let latest = historyFiles().last,
              let data = try? Data(contentsOf: latest),
              let config = try? JSONDecoder().decode(StatuslineConfig.self, from: data), config.isValid else {
            throw StatuslineStoreError.nothingToUndo
        }
        try StatuslineFiles.writeConfig(config, pool)
        try? FileManager.default.removeItem(at: latest)
        applied = StatuslineFiles.loadConfig(pool)
        draft = applied ?? config
        lastAppliedAt = clock()
        historyCount = historyFiles().count
    }

    private func archive(_ config: StatuslineConfig) throws {
        try AtomicFile.ensureDirectory(pool.statuslineDirectory, permissions: 0o700)
        try AtomicFile.ensureDirectory(pool.statuslineHistoryDirectory, permissions: 0o700)
        var url = pool.statuslineHistoryDirectory.appendingPathComponent("config-\(Timestamp.string(clock())).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = pool.statuslineHistoryDirectory.appendingPathComponent("config-\(Timestamp.string(clock()))_\(counter).json")
            counter += 1
        }
        try AtomicFile.write(try StatuslineFiles.encoder().encode(config), to: url, permissions: 0o600)
        for old in historyFiles().dropLast(Self.maxHistory) { try? FileManager.default.removeItem(at: old) }
    }

    private func historyFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pool.statuslineHistoryDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("config-") && $0.hasSuffix(".json") }.sorted()
            .map { pool.statuslineHistoryDirectory.appendingPathComponent($0) }
    }

    // MARK: Presets

    func savePreset(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let errors = draft.validationErrors()
        guard errors.isEmpty else { throw StatuslineStoreError.invalid(errors) }
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            presets[index].config = draft
        } else {
            presets.append(StatuslinePreset(id: UUID(), name: String(trimmed.prefix(40)), config: draft, createdAt: clock()))
        }
        try savePresets()
    }

    func deletePreset(_ id: UUID) throws {
        presets.removeAll { $0.id == id }
        try savePresets()
    }

    private func savePresets() throws {
        try AtomicFile.ensureDirectory(presetsFile.deletingLastPathComponent(), permissions: 0o700)
        try AtomicFile.write(try ProfileStore.encoder.encode(presets), to: presetsFile, permissions: 0o600)
    }

    // MARK: Per-profile state

    /// Turns rendering on or off for a profile. Takes effect on Claude Code's next status line refresh.
    func setManaged(_ managed: Bool, for profile: Profile, account: String?, plan: String?) throws {
        var state = profileStates[profile.id] ?? StatuslineProfileState(managed: managed)
        state.managed = managed
        state.profileName = profile.name
        state.account = account
        state.plan = plan
        try StatuslineFiles.writeProfile(state, id: profile.id, pool)
        profileStates[profile.id] = state
    }

    /// Keeps the Account / Plan / Profile components current. Writes only when something changed.
    func syncContext(for profile: Profile, account: String?, plan: String?) {
        guard var state = profileStates[profile.id] else { return }
        let updated = StatuslineProfileState(managed: state.managed, profileName: profile.name, account: account ?? state.account, plan: plan ?? state.plan)
        guard updated != state else { return }
        state = updated
        if (try? StatuslineFiles.writeProfile(state, id: profile.id, pool)) != nil { profileStates[profile.id] = state }
    }

    func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: pool.statuslineProfile(for: id))
        profileStates[id] = nil
    }

    // MARK: Editing helpers

    func add(_ kind: StatuslineWidgetKind, toLine line: Int, at position: Int? = nil) -> UUID? {
        guard draft.lines.indices.contains(line), draft.lines[line].count < StatuslineConfig.maxWidgetsPerLine else { return nil }
        var widget = StatuslineWidget(kind: kind)
        if kind == .customText { widget.text = "text" }
        if kind == .separator { widget.text = "│" }
        let index = min(max(0, position ?? draft.lines[line].count), draft.lines[line].count)
        draft.lines[line].insert(widget, at: index)
        return widget.id
    }

    /// Moves a component (by id) to `line`, before `position`; works across lines.
    func move(_ id: UUID, toLine line: Int, at position: Int) {
        guard draft.lines.indices.contains(line), let (fromLine, fromIndex) = locate(id) else { return }
        let widget = draft.lines[fromLine].remove(at: fromIndex)
        var target = position
        if fromLine == line, fromIndex < position { target -= 1 }
        target = min(max(0, target), draft.lines[line].count)
        draft.lines[line].insert(widget, at: target)
    }

    func remove(_ id: UUID) {
        guard let (line, index) = locate(id) else { return }
        draft.lines[line].remove(at: index)
    }

    func update(_ widget: StatuslineWidget) {
        guard let (line, index) = locate(widget.id) else { return }
        draft.lines[line][index] = widget
    }

    func widget(_ id: UUID) -> StatuslineWidget? {
        locate(id).map { draft.lines[$0.0][$0.1] }
    }

    func addLine() {
        guard draft.lines.count < StatuslineConfig.maxLines else { return }
        draft.lines.append([])
    }

    func removeLine(_ line: Int) {
        guard draft.lines.indices.contains(line), draft.lines.count > 1 else { return }
        draft.lines.remove(at: line)
    }

    private func locate(_ id: UUID) -> (Int, Int)? {
        for (lineIndex, line) in draft.lines.enumerated() {
            if let index = line.firstIndex(where: { $0.id == id }) { return (lineIndex, index) }
        }
        return nil
    }
}

/// Imports a ccstatusline `settings.json` (https://github.com/sirmalloc/ccstatusline) where the
/// components have an equivalent. Others are listed as skipped; nothing is invented.
enum CCStatuslineImporter {
    static let defaultLocation = ".config/ccstatusline/settings.json"

    static let kindMap: [String: StatuslineWidgetKind] = [
        "model": .model, "current-working-dir": .cwd, "git-branch": .gitBranch, "git-changes": .gitStatus, "git-status": .gitStatus,
        "context-percentage": .contextPercent, "context-percentage-usable": .contextPercent, "context-length": .contextTokens,
        "context-window": .contextTokens, "tokens-input": .tokensInOut, "tokens-output": .tokensInOut, "tokens-total": .tokensInOut,
        "tokens-cached": .cacheTokens, "cache-read": .cacheTokens, "cache-write": .cacheTokens, "session-cost": .sessionCost,
        "session-clock": .sessionDuration, "version": .version, "output-style": .outputStyle, "custom-text": .customText,
        "separator": .separator, "flex-separator": .flexSpacer, "session-usage": .fiveHourUsage, "weekly-usage": .sevenDayUsage,
        "reset-timer": .fiveHourReset, "block-timer": .fiveHourReset, "weekly-reset-timer": .sevenDayReset,
        "claude-account-email": .account, "session-name": .sessionName, "thinking-effort": .effort, "vim-mode": .vimMode,
        "git-insertions": .linesChanged,
    ]

    private struct Settings: Decodable {
        struct Widget: Decodable {
            let type: String
            let color: String?
            let backgroundColor: String?
            let bold: Bool?
            let rawValue: Bool?
            let customText: String?
            let character: String?
        }
        struct Powerline: Decodable { let enabled: Bool? }
        let lines: [[Widget]]?
        let powerline: Powerline?
        let globalBold: Bool?
        let colorLevel: Int?
    }

    static func convert(_ data: Data) throws -> (config: StatuslineConfig, skipped: [String]) {
        let settings: Settings
        do { settings = try JSONDecoder().decode(Settings.self, from: data) } catch {
            throw StatuslineStoreError.importFailed("it isn't a ccstatusline settings file.")
        }
        var skipped: [String] = []
        var lines: [[StatuslineWidget]] = []
        for line in settings.lines ?? [] {
            var converted: [StatuslineWidget] = []
            var seenKinds: Set<StatuslineWidgetKind> = []
            for item in line {
                guard let kind = kindMap[item.type] else { skipped.append(item.type); continue }
                // ccstatusline splits some values we show together (e.g. tokens in/out); keep one.
                if !kind.isLayout, kind != .customText, seenKinds.contains(kind) { continue }
                seenKinds.insert(kind)
                var widget = StatuslineWidget(kind: kind, foreground: color(item.color), background: color(item.backgroundColor),
                                              bold: item.bold ?? false, showLabel: !(item.rawValue ?? false))
                if kind == .customText { widget.text = item.customText.map { StatuslineRenderer.sanitize($0) } }
                if kind == .separator { widget.text = item.character ?? "|" }
                if kind.isLayout || kind == .customText { widget.showLabel = false }
                converted.append(widget)
            }
            if !converted.isEmpty { lines.append(Array(converted.prefix(StatuslineConfig.maxWidgetsPerLine))) }
        }
        guard !lines.isEmpty else { throw StatuslineStoreError.importFailed("no components with an equivalent were found.") }
        var config = StatuslineConfig(lines: Array(lines.prefix(StatuslineConfig.maxLines)))
        config.powerline.enabled = settings.powerline?.enabled ?? false
        config.globalBold = settings.globalBold ?? false
        switch settings.colorLevel {
        case 1: config.colorLevel = .basic
        case 2: config.colorLevel = .ansi256
        default: config.colorLevel = .truecolor
        }
        // ccstatusline separators are explicit components.
        if lines.joined().contains(where: { $0.kind == .separator }) { config.separator = " " }
        return (config, Array(Set(skipped)).sorted())
    }

    /// ccstatusline names (`brightBlack`, `cyan`), `hex:RRGGBB`, or `#RRGGBB`; others are dropped.
    static func color(_ value: String?) -> StatuslineColor? {
        guard let value, !value.isEmpty else { return nil }
        if StatuslineColor.ansiNames.contains(value) { return StatuslineColor(value) }
        let lower = value.lowercased()
        let hex = lower.hasPrefix("hex:") ? String(lower.dropFirst(4)) : (lower.hasPrefix("#") ? String(lower.dropFirst()) : "")
        if hex.count == 6, Int(hex, radix: 16) != nil { return StatuslineColor("#" + hex.uppercased()) }
        if let named = StatuslineColor.ansiNames.first(where: { $0.lowercased() == lower }) { return StatuslineColor(named) }
        return nil
    }
}
