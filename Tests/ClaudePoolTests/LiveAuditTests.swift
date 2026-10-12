import Foundation
import Testing
@testable import ClaudePool

/// Checks the app's services against the REAL environment: the installed `claude`, your real
/// Keychain sign-ins, your login shell and your registered profiles. Read-only: nothing in your
/// home folder is written. Run with `make live-check` (sets CLAUDE_POOL_LIVE=1).
///
/// Ground truth comes from running the same command through your interactive login shell,
/// i.e. exactly what you would see typing it in Terminal.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLAUDE_POOL_LIVE"] == "1"))
struct LiveAuditTests {
    let paths = Paths.live()

    private func binary() async throws -> ClaudeBinary {
        try #require(await ClaudeBinaryLocator(home: paths.userHome).locate(override: nil), "claude binary not found")
    }

    private func profiles() throws -> [Profile] {
        guard let data = try? Data(contentsOf: paths.profilesFile) else { return [Profile.makeDefault(home: paths.userHome)] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Profile].self, from: data).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// `claude auth status` as you'd run it in Terminal: full login-shell environment.
    private func groundTruth(_ profile: Profile, binary: ClaudeBinary) throws -> (exit: Int32, method: String?) {
        let prefix = profile.configDirEnvironmentValue.map { "CLAUDE_CONFIG_DIR=\(ShellQuote.quote($0)) " } ?? "unset CLAUDE_CONFIG_DIR; "
        let script = "\(prefix)\(ShellQuote.quote(binary.path)) auth status; print -r -- \"CP_EXIT:$?\""
        let result = try runProcess(URL(fileURLWithPath: "/bin/zsh"), ["-ilc", script], environment: ChildEnvironment.loginShell(home: paths.userHome))
        let text = result.stdoutText
        let exitLine = text.split(separator: "\n").last { $0.hasPrefix("CP_EXIT:") }
        let exit = Int32(exitLine?.dropFirst("CP_EXIT:".count) ?? "") ?? -1
        let jsonStart = text.firstIndex(of: "{"), jsonEnd = text.lastIndex(of: "}")
        var method: String?
        if let jsonStart, let jsonEnd {
            method = AuthStatusParser.allowedFields(from: Data(text[jsonStart...jsonEnd].utf8))["authMethod"]
        }
        return (exit, method)
    }

    @Test func binaryIsFoundWithVersion() async throws {
        let binary = try await binary()
        print("LIVE binary: \(binary.path) via \(binary.source.rawValue) — \(binary.version ?? "NO VERSION")")
        #expect(binary.version != nil)
    }

    /// Regression: the app reported "Signed out" for a signed-in Default profile because the
    /// child environment lacked USER, which Claude Code needs to find its Keychain sign-in.
    @Test func signInMatchesTerminalForEveryProfile() async throws {
        let binary = try await binary()
        let service = AuthStatusService(home: paths.userHome)
        for profile in try profiles() {
            let truth = try groundTruth(profile, binary: binary)
            let app = try await service.check(profile, binary: binary)
            print("LIVE auth \(profile.name): app signedIn=\(app.signedIn) method=\(app.authMethod ?? "-") dir=\(app.configDirectory ?? "-") | terminal exit=\(truth.exit) method=\(truth.method ?? "-")")
            #expect(app.signedIn == (truth.exit == 0), "\(profile.name): app and Terminal disagree about sign-in")
            #expect(app.authMethod == truth.method, "\(profile.name): auth method differs")
            if let reported = app.configDirectory {
                #expect(Paths.canonical(reported) == Paths.canonical(profile.configDir), "\(profile.name): isolation mismatch")
            }
        }
    }

    @Test func emptyDirectoryIsSignedOutAndIsolated() async throws {
        let binary = try await binary()
        let temp = try TempDirectory()
        var profile = Profile.makeDefault(home: temp.url)
        profile.isDefault = false
        profile.configDir = temp.url.path
        let status = try await AuthStatusService(home: paths.userHome).check(profile, binary: binary)
        #expect(!status.signedIn)
        #expect(status.configDirectory.map(Paths.canonical) == Paths.canonical(temp.url.path))
    }

    @Test func shellProbesAnswerInTime() async throws {
        let service = DiagnosticsService(home: paths.userHome, loginShell: ShellIntegrationService.currentLoginShell())
        let start = Date()
        let function = await service.probeShellFunction()
        let names = await service.probeConflictingVariables()
        print("LIVE probes (\(String(format: "%.1f", Date().timeIntervalSince(start)))s): whence=\(function ?? "nil") exported=\(names ?? ["probe failed"])")
        #expect(function != nil, "the login shell did not answer within 5s")
        #expect(names != nil)
    }

    /// Every displayed state, computed from real snapshots and real sign-in results.
    @MainActor
    @Test func usageStatesAreConsistentWithSignIn() async throws {
        let binary = try await binary()
        let service = AuthStatusService(home: paths.userHome)
        let patcher = SettingsPatcher(pool: paths.pool)
        let usage = UsageStore(pool: paths.pool)
        usage.reload()
        let now = Date()
        let formatting = UsageFormatting(now: now)
        for profile in try profiles() {
            let auth = try await service.check(profile, binary: binary)
            let snapshot = usage.snapshot(for: profile.id)
            let tracking = patcher.state(for: profile)
            print("LIVE profile \(profile.name): tracking app=\(profile.trackingEnabled) settings=\(tracking.label) signedIn=\(auth.signedIn) plan=\(auth.subscriptionType ?? "-")")
            if profile.trackingEnabled { #expect(tracking == .enabled, "\(profile.name): statusLine no longer points at the collector") }
            for kind in UsageWindowKind.allCases {
                let state = UsageFormatting.state(for: kind, trackingEnabled: profile.trackingEnabled, auth: auth, snapshot: snapshot, now: now)
                let text = state.displayedWindow.map { "\(UsageFormatting.percentText($0.usedPercentage)) \(formatting.resetText($0, kind: kind)) \(formatting.observationText(state) ?? "")" }
                    ?? formatting.stateText(state, kind: kind) ?? ""
                print("LIVE   \(kind.shortLabel): \(text)")
                if auth.signedIn { #expect(state != .signedOut) }
                // A window the collector recorded must be displayed (value or reset), unless tracking is off.
                if profile.trackingEnabled, auth.signedIn, auth.reportsUsage, snapshot?.window(kind) != nil {
                    #expect(state.displayedWindow != nil || { if case .resetPassed = state { true } else { false } }(), "\(profile.name) \(kind): recorded data not shown")
                }
            }
        }
    }

    @Test func installedCollectorMatchesBuild() throws {
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ClaudePool.app/Contents/Helpers/claude-pool-collector")
        try #require(FileManager.default.fileExists(atPath: built.path), "run make build first")
        let state = CollectorInstaller(pool: paths.pool, bundledHelper: built).state()
        print("LIVE collector: \(state)")
        #expect(state == .upToDate || state == .outdated, "collector missing from ~/.claude-pool/bin")
    }

    /// Plan shown for each real profile, from `claude auth status` plus Claude Code's cached account data.
    @Test func planDetectionForRealProfiles() async throws {
        let binary = try await binary()
        let service = AuthStatusService(home: paths.userHome)
        for profile in try profiles() {
            let status = try await service.check(profile, binary: binary)
            let details = AccountDetailsReader.read(profile, home: paths.userHome)
            let plan = SubscriptionPlan.resolve(subscriptionType: status.subscriptionType, details: details, signedInEmail: status.email)
            print("LIVE plan \(profile.name): auth subscriptionType=\(status.subscriptionType ?? "-") tier=\(details?.rateLimitTier ?? "-") → \(plan?.displayName ?? "none") (source \(plan?.source.rawValue ?? "-"))")
            if status.signedIn, status.subscriptionType == "max", details?.rateLimitTier?.contains("max_") == true {
                #expect(plan?.multiplier != nil, "\(profile.name): Max with a cached tier must show its multiplier")
            }
        }
    }

    /// Every live session the app lists is a real, running `claude` whose CLAUDE_CONFIG_DIR matches
    /// the profile it is listed under (ground truth from `ps eww`, environment of the same process).
    @Test func sessionRegistryMatchesRunningProcesses() throws {
        let sessions = SessionRegistryService().sessions(for: try profiles())
        print("LIVE sessions: \(sessions.count)")
        let profilesByID = Dictionary(uniqueKeysWithValues: try profiles().map { ($0.id, $0) })
        for session in sessions {
            let ps = try runProcess(URL(fileURLWithPath: "/bin/ps"), ["eww", "-o", "command=", "-p", "\(session.pid)"], environment: [:])
            let text = ps.stdoutText
            let configDir = text.split(separator: " ").first { $0.hasPrefix("CLAUDE_CONFIG_DIR=") }.map { String($0.dropFirst("CLAUDE_CONFIG_DIR=".count)) }
            let profile = try #require(profilesByID[session.profileID])
            print("LIVE session pid \(session.pid) \(session.folderName) [\(session.status ?? "-")] listed under \(profile.name); process CLAUDE_CONFIG_DIR=\(configDir ?? "unset")")
            #expect(text.contains("claude"), "pid \(session.pid) is not a claude process")
            if profile.isDefault {
                #expect(configDir == nil || Paths.canonical(configDir!) == Paths.canonical(profile.configDir))
            } else {
                #expect(configDir.map { Paths.canonical($0) } == Paths.canonical(profile.configDir), "pid \(session.pid): listed under \(profile.name) but runs with \(configDir ?? "unset")")
            }
        }
    }
}
