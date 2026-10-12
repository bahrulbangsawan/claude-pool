import Foundation
import Testing
@testable import ClaudePool

@Suite struct AuthStatusParserTests {
    let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesSignedInSubscription() throws {
        let status = try #require(AuthStatusParser.parse(stdout: Fixtures.data("auth-status-claudeai.json"), exitCode: 0, checkedAt: checkedAt))
        #expect(status.signedIn)
        #expect(status.authMethod == "claude.ai")
        #expect(status.reportsUsage)
        #expect(status.configDirectory == "/Users/example/.claude-work")
        #expect(status.identityLabel == "person@example.com · Example Org")
        #expect(status.subscriptionType == "max")
        #expect(status.checkedAt == checkedAt)
    }

    @Test func parsesSignedOut() throws {
        let status = try #require(AuthStatusParser.parse(stdout: Fixtures.data("auth-status-signed-out.json"), exitCode: 1, checkedAt: checkedAt))
        #expect(!status.signedIn)
        #expect(status.authMethod == "none")
        #expect(status.identityLabel == nil)
    }

    @Test func exitCodeMapping() {
        let json = Data(#"{"loggedIn":true}"#.utf8)
        #expect(AuthStatusParser.parse(stdout: json, exitCode: 0, checkedAt: checkedAt)?.signedIn == true)
        #expect(AuthStatusParser.parse(stdout: json, exitCode: 1, checkedAt: checkedAt)?.signedIn == false)
        #expect(AuthStatusParser.parse(stdout: json, exitCode: 2, checkedAt: checkedAt) == nil)
        #expect(AuthStatusParser.parse(stdout: json, exitCode: -1, checkedAt: checkedAt) == nil)
        // Exit code is authoritative even when the output is not JSON.
        let garbage = AuthStatusParser.parse(stdout: Data("oops".utf8), exitCode: 0, checkedAt: checkedAt)
        #expect(garbage?.signedIn == true)
        #expect(garbage?.authMethod == nil)
    }

    @Test func missingConfigDirectory() throws {
        let status = try #require(AuthStatusParser.parse(stdout: Fixtures.data("auth-status-no-configdir.json"), exitCode: 0, checkedAt: checkedAt))
        #expect(status.configDirectory == nil)
        #expect(status.identityLabel == "person@example.com")
    }

    @Test func forbiddenFieldsAreDropped() throws {
        let data = try Fixtures.data("auth-status-forbidden-fields.json")
        let fields = AuthStatusParser.allowedFields(from: data)
        #expect(Set(fields.keys).isSubset(of: AuthStatusParser.whitelist))
        #expect(Set(fields.keys) == ["loggedIn", "authMethod", "email", "orgName"])
        #expect(!fields.values.contains { $0.contains("SHOULD-NEVER-APPEAR") || $0.contains("ANTHROPIC_API_KEY") })

        let status = try #require(AuthStatusParser.parse(stdout: data, exitCode: 0, checkedAt: checkedAt))
        #expect(!String(describing: status).contains("SHOULD-NEVER-APPEAR"))
        #expect(status.authMethod == "api_key")
        #expect(!status.reportsUsage)
    }

    @Test func nameRulesRejectSecretsEvenIfWhitelisted() {
        for name in ["accessToken", "apiKey", "apiKeySource", "clientSecret", "credentialPath", "TOKEN", "oauthToken"] {
            #expect(!AuthStatusParser.isAllowed(name))
        }
        for name in ["projectsDirectory", "apiProvider", "analyticsDisabled"] {
            #expect(!AuthStatusParser.isAllowed(name), "\(name) is not whitelisted")
        }
        for name in AuthStatusParser.whitelist {
            #expect(AuthStatusParser.isAllowed(name))
        }
    }

    @Test func nonStringValuesAreIgnored() {
        let data = Data(#"{"authMethod":{"nested":"x"},"email":42,"orgName":["a"],"loggedIn":true}"#.utf8)
        let fields = AuthStatusParser.allowedFields(from: data)
        #expect(fields == ["loggedIn": "true"])
    }

    @Test func environmentIsExplicitAndMinimal() {
        let service = AuthStatusService(home: URL(fileURLWithPath: "/Users/example"))
        let binary = ClaudeBinary(path: "/Users/example/.local/bin/claude", source: .fallback)
        var profile = Profile.makeDefault(home: URL(fileURLWithPath: "/Users/example"))
        let defaultEnv = service.environment(for: profile, binary: binary)
        let user = NSUserName()
        #expect(defaultEnv == ["HOME": "/Users/example", "USER": user, "LOGNAME": user, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/Users/example/.local/bin"])
        #expect(defaultEnv["CLAUDE_CONFIG_DIR"] == nil, "Default runs with CLAUDE_CONFIG_DIR absent")
        profile.isDefault = false
        profile.configDir = "/Users/example/.claude-work"
        #expect(service.environment(for: profile, binary: binary)["CLAUDE_CONFIG_DIR"] == "/Users/example/.claude-work")
    }

    @Test func runnerScrubsCredentialVariables() async throws {
        let result = try await ProcessRunner(maxConcurrent: 2).run(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
            environment: ["HOME": "/tmp", "ANTHROPIC_API_KEY": "x", "ANTHROPIC_AUTH_TOKEN": "y", "ANTHROPIC_BASE_URL": "z", "KEEP": "1"],
            timeout: 5
        )
        let names = result.stdoutText.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) }
        #expect(Set(names) == ["HOME", "KEEP"])
    }

    @Test func runnerKillsOnTimeout() async throws {
        let start = Date()
        let result = try await ProcessRunner(maxConcurrent: 2).run(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], environment: [:], timeout: 0.5
        )
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
