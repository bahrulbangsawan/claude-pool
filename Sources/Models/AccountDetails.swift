import Foundation

/// Non-secret account facts that Claude Code caches in its global config file
/// (`$HOME/.claude.json` for Default, `<configDir>/.claude.json` otherwise), under `oauthAccount`.
///
/// Compliance: only the keys declared in `OAuthAccount` below are ever decoded. Every other key in
/// that file (projects, history, MCP servers, API keys, …) is never declared, so never read or kept.
/// Held in memory only.
struct AccountDetails: Hashable, Sendable {
    var emailAddress: String?
    var accountUUID: String?
    var organizationUUID: String?
    var organizationName: String?
    /// e.g. `claude_max`, `claude_pro`, `claude_team`, `claude_enterprise`.
    var organizationType: String?
    /// e.g. `default_claude_max_20x`. Claude Code's own name for the rate-limit tier.
    var organizationRateLimitTier: String?
    var userRateLimitTier: String?
    /// Team/Enterprise seat, e.g. `standard`, `premium`.
    var seatTier: String?
    /// Plan name supplied by the account profile endpoint, when Claude Code cached one.
    var planDisplayName: String?
    var billingType: String?
    var hasExtraUsageEnabled: Bool?
    /// When Claude Code last refreshed this profile from the server.
    var profileFetchedAt: Date?
    /// When Claude Pool read the file.
    var readAt: Date

    /// The user-level tier wins over the organisation-level one, matching how Claude Code applies them.
    var rateLimitTier: String? { userRateLimitTier ?? organizationRateLimitTier }
}

enum AccountDetailsReader {
    /// What Claude Code uses: `$CLAUDE_CONFIG_DIR/.claude.json`, or `$HOME/.claude.json` when unset.
    static func configFile(for profile: Profile, home: URL) -> URL {
        if profile.isDefault { return home.appendingPathComponent(".claude.json") }
        return profile.configURL.appendingPathComponent(".claude.json")
    }

    private struct File: Decodable {
        let oauthAccount: OAuthAccount?
    }

    /// The only keys ever decoded. Do not add credential-like keys.
    private struct OAuthAccount: Decodable {
        let emailAddress: String?
        let accountUuid: String?
        let organizationUuid: String?
        let organizationName: String?
        let organizationType: String?
        let organizationRateLimitTier: String?
        let userRateLimitTier: String?
        let seatTier: String?
        let planDisplayName: String?
        let billingType: String?
        let hasExtraUsageEnabled: Bool?
        let profileFetchedAt: Double?
    }

    static func read(_ profile: Profile, home: URL, now: Date = Date()) -> AccountDetails? {
        guard let data = try? Data(contentsOf: configFile(for: profile, home: home), options: .mappedIfSafe) else { return nil }
        return parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) -> AccountDetails? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), let account = file.oauthAccount else { return nil }
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return String(value.prefix(128))
        }
        return AccountDetails(
            emailAddress: clean(account.emailAddress),
            accountUUID: clean(account.accountUuid),
            organizationUUID: clean(account.organizationUuid),
            organizationName: clean(account.organizationName),
            organizationType: clean(account.organizationType),
            organizationRateLimitTier: clean(account.organizationRateLimitTier),
            userRateLimitTier: clean(account.userRateLimitTier),
            seatTier: clean(account.seatTier),
            planDisplayName: clean(account.planDisplayName),
            billingType: clean(account.billingType),
            hasExtraUsageEnabled: account.hasExtraUsageEnabled,
            profileFetchedAt: account.profileFetchedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            readAt: now
        )
    }
}

/// The subscription plan, as specific as the available data allows. A tier ("20x") is only shown
/// when Claude Code's own account data names it; a bare "max" never becomes a guessed tier.
struct SubscriptionPlan: Hashable, Sendable {
    enum Family: String, Sendable {
        case pro, max, team, enterprise, unknown

        var label: String {
            switch self {
            case .pro: "Pro"
            case .max: "Max"
            case .team: "Team"
            case .enterprise: "Enterprise"
            case .unknown: "Unknown plan"
            }
        }
    }

    enum Source: String, Sendable {
        /// `planDisplayName` from the account profile Claude Code cached.
        case planName
        /// `subscriptionType` from `claude auth status` plus the rate-limit tier Claude Code cached.
        case rateLimitTier
        /// `subscriptionType` from `claude auth status` only.
        case subscriptionType
    }

    var family: Family
    /// "5x", "20x" — only when verified from account data.
    var multiplier: Int?
    var seat: String?
    var displayName: String
    var source: Source
    /// False when the family is known but its tier is not.
    var isTierKnown: Bool

    /// Combines the authoritative `subscriptionType` with the cached account details.
    /// Details are ignored when they belong to a different email than the signed-in one (stale cache).
    static func resolve(subscriptionType: String?, details: AccountDetails?, signedInEmail: String?) -> SubscriptionPlan? {
        var details = details
        if let email = signedInEmail?.lowercased(), let cached = details?.emailAddress?.lowercased(), email != cached {
            details = nil
        }
        let family = family(subscriptionType: subscriptionType, organizationType: details?.organizationType)
        if family == .unknown, subscriptionType == nil, details?.organizationType == nil { return nil }

        let seat = details?.seatTier.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        if let name = details?.planDisplayName, isSafeLabel(name) {
            return SubscriptionPlan(family: family, multiplier: multiplier(in: details?.rateLimitTier), seat: seat,
                                    displayName: name, source: .planName, isTierKnown: true)
        }
        switch family {
        case .max:
            if let n = multiplier(in: details?.rateLimitTier), details?.rateLimitTier?.contains("max") == true {
                return SubscriptionPlan(family: .max, multiplier: n, seat: nil, displayName: "Max \(n)x", source: .rateLimitTier, isTierKnown: true)
            }
            return SubscriptionPlan(family: .max, multiplier: nil, seat: nil, displayName: "Max · Unknown Tier", source: .subscriptionType, isTierKnown: false)
        case .team, .enterprise:
            if let seat {
                return SubscriptionPlan(family: family, multiplier: nil, seat: seat, displayName: "\(family.label) · \(seat) seat", source: .rateLimitTier, isTierKnown: true)
            }
            return SubscriptionPlan(family: family, multiplier: nil, seat: nil, displayName: family.label, source: .subscriptionType, isTierKnown: false)
        case .pro:
            return SubscriptionPlan(family: .pro, multiplier: nil, seat: nil, displayName: "Pro", source: .subscriptionType, isTierKnown: true)
        case .unknown:
            let raw = subscriptionType.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Unknown plan"
            return SubscriptionPlan(family: .unknown, multiplier: nil, seat: nil, displayName: raw, source: .subscriptionType, isTierKnown: false)
        }
    }

    static func family(subscriptionType: String?, organizationType: String?) -> Family {
        switch subscriptionType?.lowercased() {
        case "pro": return .pro
        case "max": return .max
        case "team": return .team
        case "enterprise": return .enterprise
        case .some: return .unknown
        case nil: break
        }
        switch organizationType?.lowercased() {
        case "claude_pro": return .pro
        case "claude_max": return .max
        case "claude_team": return .team
        case "claude_enterprise": return .enterprise
        default: return .unknown
        }
    }

    /// `default_claude_max_20x` → 20. Nil for anything without an explicit `_<n>x` suffix.
    static func multiplier(in tier: String?) -> Int? {
        guard let tier = tier?.lowercased(),
              let match = tier.firstMatch(of: /_(\d{1,3})x$/),
              let value = Int(match.1), value > 0 else { return nil }
        return value
    }

    private static func isSafeLabel(_ value: String) -> Bool {
        value.count <= 40 && value.allSatisfy { $0.isLetter || $0.isNumber || " -·+().".contains($0) }
    }
}
