import Foundation
import Testing
@testable import ClaudePool

@Suite struct DiagnosticsServiceTests {
    let temp: TempDirectory
    let defaultProfile: Profile

    init() throws {
        temp = try TempDirectory()
        defaultProfile = Profile.makeDefault(home: temp.paths.userHome)
        try FileManager.default.createDirectory(at: defaultProfile.configURL, withIntermediateDirectories: true)
    }

    private func input(
        variables: [String]? = [],
        pointer: String? = nil,
        auth: AuthStatus? = nil,
        profiles: [Profile]? = nil
    ) -> DiagnosticsInput {
        DiagnosticsInput(
            binary: ClaudeBinary(path: "/x/claude", source: .loginShell, version: "2.1.296 (Claude Code)"),
            shellStatus: .installed,
            shellFunctionProbe: "claude: function",
            conflictingVariables: variables,
            pointerValue: pointer,
            pointerError: nil,
            profiles: profiles ?? [defaultProfile],
            authStatuses: auth.map { [defaultProfile.id: $0] } ?? [:],
            authErrors: [:],
            trackingStates: [:],
            collectorState: .upToDate
        )
    }

    private func check(_ id: String, in checks: [DiagnosticCheck]) -> DiagnosticCheck? {
        checks.first { $0.id == id }
    }

    @Test func healthySetupPasses() {
        let checks = DiagnosticsService.evaluate(input())
        for id in ["binary", "shell", "env", "pointer", "dirs", "collector"] {
            #expect(check(id, in: checks)?.status == .pass, "\(id)")
        }
        #expect(check("info-limits", in: checks)?.status == .info)
    }

    @Test func credentialVariablesFailByNameOnly() {
        let checks = DiagnosticsService.evaluate(input(variables: ["ANTHROPIC_API_KEY"]))
        let env = check("env", in: checks)
        #expect(env?.status == .fail)
        #expect(env?.detail.contains("ANTHROPIC_API_KEY") == true)
        #expect(check("env", in: DiagnosticsService.evaluate(input(variables: ["CLAUDE_CONFIG_DIR"])))?.status == .warn)
    }

    @Test func pointerToUnknownDirectoryFails() {
        let checks = DiagnosticsService.evaluate(input(pointer: "/nowhere"))
        #expect(check("pointer", in: checks)?.status == .fail)
    }

    @Test func isolationMismatchFails() {
        let status = AuthStatus(signedIn: true, authMethod: "claude.ai", configDirectory: "/some/other", identityLabel: nil, subscriptionType: nil, checkedAt: Date())
        let checks = DiagnosticsService.evaluate(input(auth: status))
        #expect(check("profile-\(defaultProfile.id.uuidString)-isolation", in: checks)?.status == .fail)
    }

    @Test func apiKeySignInWarns() {
        let status = AuthStatus(signedIn: true, authMethod: "api_key", configDirectory: defaultProfile.configDir, identityLabel: nil, subscriptionType: nil, checkedAt: Date())
        let checks = DiagnosticsService.evaluate(input(auth: status))
        #expect(check("profile-\(defaultProfile.id.uuidString)-method", in: checks)?.status == .warn)
        #expect(check("profile-\(defaultProfile.id.uuidString)-isolation", in: checks)?.status == .pass)
    }

    @Test func probeStringPrintsNamesOnly() throws {
        // Run the real probe in a clean zsh with a fake secret exported: only the name comes back.
        let result = try runProcess(
            URL(fileURLWithPath: "/bin/zsh"), ["-f", "-c", DiagnosticsService.environmentProbe],
            environment: ["ANTHROPIC_API_KEY": "sk-should-not-print", "CLAUDE_CONFIG_DIR": "/x", "PATH": "/usr/bin:/bin"]
        )
        #expect(result.stdoutText == "CP_SET:ANTHROPIC_API_KEY\nCP_SET:CLAUDE_CONFIG_DIR\n")
        #expect(!result.stdoutText.contains("sk-should-not-print"))
    }
}
