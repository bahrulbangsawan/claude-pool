import Foundation

/// One rate-limit window exactly as Claude Code reported it.
public struct UsageWindow: Codable, Hashable, Sendable {
    /// 0–100, as reported. Never computed by this app.
    public var usedPercentage: Double
    public var resetsAt: Date

    public init(usedPercentage: Double, resetsAt: Date) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

/// Latest observed usage for one profile, stored at `~/.claude-pool/usage/<UUID>.json`.
public struct UsageSnapshot: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var profileId: UUID
    /// Last time any window was present in a status line payload.
    public var observedAt: Date?
    /// Last time any status line run happened for this profile.
    public var lastSeenAt: Date
    public var claudeVersion: String?
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?

    public init(
        schema: Int = UsageSnapshot.currentSchema,
        profileId: UUID,
        observedAt: Date? = nil,
        lastSeenAt: Date,
        claudeVersion: String? = nil,
        fiveHour: UsageWindow? = nil,
        sevenDay: UsageWindow? = nil
    ) {
        self.schema = schema
        self.profileId = profileId
        self.observedAt = observedAt
        self.lastSeenAt = lastSeenAt
        self.claudeVersion = claudeVersion
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// One line of `<UUID>.history.jsonl`. Only windows present in that status line run are recorded.
public struct UsageHistoryEntry: Codable, Hashable, Sendable {
    /// Observation time, Unix epoch seconds.
    public var t: Double
    /// 5-hour used percentage and reset time (epoch seconds).
    public var fh: Double?
    public var fhr: Double?
    /// 7-day used percentage and reset time (epoch seconds).
    public var sd: Double?
    public var sdr: Double?

    public init(t: Double, fh: Double? = nil, fhr: Double? = nil, sd: Double? = nil, sdr: Double? = nil) {
        self.t = t
        self.fh = fh
        self.fhr = fhr
        self.sd = sd
        self.sdr = sdr
    }

    public var date: Date { Date(timeIntervalSince1970: t) }

    /// True when the reported values match, ignoring the timestamp.
    public func hasSameValues(as other: UsageHistoryEntry) -> Bool {
        fh == other.fh && fhr == other.fhr && sd == other.sd && sdr == other.sdr
    }
}

/// Encoders shared by the collector (writer) and the app (reader).
public enum UsageCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
