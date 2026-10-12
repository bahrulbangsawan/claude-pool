import Foundation

/// Non-secret sign-in facts from `claude auth status`. Held in memory only; never persisted.
struct AuthStatus: Hashable, Sendable {
    var signedIn: Bool
    var authMethod: String?
    var configDirectory: String?
    var identityLabel: String?     // display-only, from whitelisted identity fields
    var subscriptionType: String?  // display-only, e.g. "pro", "max", "team"
    var checkedAt: Date
    var email: String?             // display-only; also used to detect two profiles on one account
    var orgId: String?             // non-secret organisation identifier, for duplicate detection
    var orgName: String?

    /// Same account and organisation, compared case-insensitively. Nil when either side is unknown.
    func isSameAccount(as other: AuthStatus) -> Bool? {
        guard let email = email?.lowercased(), let otherEmail = other.email?.lowercased() else { return nil }
        guard email == otherEmail else { return false }
        if let orgId, let otherOrg = other.orgId { return orgId == otherOrg }
        return true
    }

    static let subscriptionAuthMethod = "claude.ai"

    /// Usage windows only exist for claude.ai sign-ins.
    var reportsUsage: Bool { authMethod == nil || authMethod == Self.subscriptionAuthMethod }

    var authMethodLabel: String {
        switch authMethod {
        case nil: "unknown"
        case "none": "none"
        case "claude.ai": "claude.ai subscription"
        case "oauth_token": "OAuth token (env)"
        case "api_key": "API key"
        case "api_key_helper": "apiKeyHelper"
        case "third_party": "third-party provider"
        case let other?: other
        }
    }
}
