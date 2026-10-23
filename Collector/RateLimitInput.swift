import CommonCrypto
import Foundation

/// The only part of Claude Code's status line JSON this tool decodes for usage: `rate_limits`,
/// `version`, and `session_id`, which is hashed at once and used only to tell concurrent sessions
/// apart (see `ReporterLog`); the ID itself is never stored.
///
/// Compliance: do not add fields. Every other key in the payload (paths, cost, model,
/// workspace, …) is never declared here, so it is never decoded or stored.
struct RateLimitInput: Decodable {
    struct Window: Decodable {
        let usedPercentage: Double
        let resetsAt: Double

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        var isValid: Bool {
            usedPercentage.isFinite && resetsAt.isFinite && resetsAt > 0
        }
    }

    struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }

        // Each window may be independently absent or malformed; a bad one is treated as absent.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = (try? container.decodeIfPresent(Window.self, forKey: .fiveHour)).flatMap { $0 }.flatMap { $0.isValid ? $0 : nil }
            sevenDay = (try? container.decodeIfPresent(Window.self, forKey: .sevenDay)).flatMap { $0 }.flatMap { $0.isValid ? $0 : nil }
        }
    }

    let rateLimits: RateLimits?
    let version: String?
    /// One-way hash of the payload's `session_id`; nil when it has none.
    let sessionKey: String?

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
        case version
        case sessionID = "session_id"
    }

    // Throws only when the payload is not a JSON object.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = (try? container.decodeIfPresent(RateLimits.self, forKey: .rateLimits)).flatMap { $0 }
        version = (try? container.decodeIfPresent(String.self, forKey: .version)).flatMap { $0 }
        sessionKey = (try? container.decodeIfPresent(String.self, forKey: .sessionID)).flatMap { $0 }
            .flatMap { $0.isEmpty ? nil : Self.hash($0) }
    }

    /// First 8 bytes of SHA-256, as hex: enough to tell sessions apart, not to recover the ID.
    static func hash(_ sessionID: String) -> String {
        let data = Data("claude-pool:\(sessionID)".utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var fiveHour: Window? { rateLimits?.fiveHour }
    var sevenDay: Window? { rateLimits?.sevenDay }
    var hasAnyWindow: Bool { fiveHour != nil || sevenDay != nil }

    static func decode(_ data: Data) throws -> RateLimitInput {
        try JSONDecoder().decode(RateLimitInput.self, from: data)
    }
}
