import Foundation

/// App preferences, stored at `~/Library/Application Support/ClaudePool/settings.json`.
struct AppSettings: Codable, Hashable, Sendable {
    var claudePathOverride: String?
    var defaultWorkingDirectory: String = "~"
    var showNameInMenuBar: Bool = true
    /// Active profile's 5-hour and 7-day usage, as "5h:23% · 7d:41%".
    var showActiveUsageInMenuBar: Bool = true
    /// The Mac's CPU and memory use, as "CPU 12% · MEM 64%".
    var showSystemStatsInMenuBar: Bool = true
    /// Opt-in: a notification when a window reaches `limitAlertThreshold` and when it reaches 100%.
    var limitAlertsEnabled: Bool = false
    var limitAlertThreshold: Int = 90
    /// Opt-in: name the account with the most room left when the active one is near or at a limit.
    var suggestAccountEnabled: Bool = false
    var collectorOutput: CollectorOutputMode = .summary
    var lastHistoryPrune: Date?

    init() {}

    // Tolerates missing keys so older files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        claudePathOverride = try c.decodeIfPresent(String.self, forKey: .claudePathOverride)
        defaultWorkingDirectory = try c.decodeIfPresent(String.self, forKey: .defaultWorkingDirectory) ?? defaults.defaultWorkingDirectory
        showNameInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showNameInMenuBar) ?? defaults.showNameInMenuBar
        showActiveUsageInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showActiveUsageInMenuBar) ?? defaults.showActiveUsageInMenuBar
        showSystemStatsInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showSystemStatsInMenuBar) ?? defaults.showSystemStatsInMenuBar
        limitAlertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .limitAlertsEnabled) ?? defaults.limitAlertsEnabled
        limitAlertThreshold = try c.decodeIfPresent(Int.self, forKey: .limitAlertThreshold) ?? defaults.limitAlertThreshold
        suggestAccountEnabled = try c.decodeIfPresent(Bool.self, forKey: .suggestAccountEnabled) ?? defaults.suggestAccountEnabled
        collectorOutput = try c.decodeIfPresent(CollectorOutputMode.self, forKey: .collectorOutput) ?? defaults.collectorOutput
        lastHistoryPrune = try c.decodeIfPresent(Date.self, forKey: .lastHistoryPrune)
    }
}
