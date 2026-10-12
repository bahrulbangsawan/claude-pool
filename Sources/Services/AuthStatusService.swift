import Foundation

/// Parses `claude auth status` output through an explicit whitelist.
///
/// Key names were taken from Claude Code 2.1.296 output: loggedIn, authMethod, apiProvider,
/// analyticsDisabled, projectsDirectory, configDirectory, email, orgId, orgName, subscriptionType.
/// Only the keys below are read. Everything else is dropped and never stored or logged.
enum AuthStatusParser {
    static let whitelist: Set<String> = [
        "loggedIn", "authMethod", "configDirectory", "email", "orgId", "orgName", "subscriptionType",
    ]
    static let forbiddenNameFragments = ["token", "key", "secret", "credential"]

    /// The whitelisted, non-secret string fields of the JSON. Booleans are kept as "true"/"false".
    static func allowedFields(from stdout: Data) -> [String: String] {
        guard let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] else { return [:] }
        var fields: [String: String] = [:]
        for (name, value) in object where isAllowed(name) {
            switch value {
            case let string as String:
                fields[name] = String(string.prefix(256))
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                fields[name] = number.boolValue ? "true" : "false"
            default:
                continue
            }
        }
        return fields
    }

    static func isAllowed(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard !forbiddenNameFragments.contains(where: lower.contains) else { return false }
        return whitelist.contains(name)
    }

    /// Exit 0 = signed in, 1 = signed out, anything else = unknown (nil).
    static func parse(stdout: Data, exitCode: Int32, checkedAt: Date) -> AuthStatus? {
        let signedIn: Bool
        switch exitCode {
        case 0: signedIn = true
        case 1: signedIn = false
        default: return nil
        }
        let fields = allowedFields(from: stdout)
        let identity = [fields["email"], fields["orgName"]]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        return AuthStatus(
            signedIn: signedIn,
            authMethod: fields["authMethod"],
            configDirectory: fields["configDirectory"],
            identityLabel: identity.isEmpty ? nil : identity,
            subscriptionType: fields["subscriptionType"],
            checkedAt: checkedAt,
            email: fields["email"].flatMap { $0.isEmpty ? nil : $0 },
            orgId: fields["orgId"].flatMap { $0.isEmpty ? nil : $0 },
            orgName: fields["orgName"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

enum AuthStatusError: Error, LocalizedError {
    case timedOut
    case unexpectedExit(Int32)

    var errorDescription: String? {
        switch self {
        case .timedOut: "Checking sign-in timed out after 10 seconds. Run claude auth status in Terminal to see why, then click Refresh."
        case let .unexpectedExit(code): "Couldn't check sign-in (claude auth status exited with code \(code)). Run it in Terminal to see the error, then click Refresh."
        }
    }
}

/// Runs the unmodified `claude auth status` for one profile.
struct AuthStatusService: Sendable {
    let home: URL
    var runner: ProcessRunner = .shared

    /// HOME, USER, LOGNAME, a fixed PATH, and CLAUDE_CONFIG_DIR only for non-default profiles.
    func environment(for profile: Profile, binary: ClaudeBinary) -> [String: String] {
        ChildEnvironment.claude(home: home, binary: binary, configDir: profile.configDirEnvironmentValue)
    }

    func check(_ profile: Profile, binary: ClaudeBinary) async throws -> AuthStatus {
        let result = try await runner.run(
            binary.url,
            arguments: ["auth", "status"],
            environment: environment(for: profile, binary: binary),
            timeout: 10
        )
        if result.timedOut { throw AuthStatusError.timedOut }
        guard let status = AuthStatusParser.parse(stdout: result.stdout, exitCode: result.exitCode, checkedAt: Date()) else {
            throw AuthStatusError.unexpectedExit(result.exitCode)
        }
        return status
    }
}
