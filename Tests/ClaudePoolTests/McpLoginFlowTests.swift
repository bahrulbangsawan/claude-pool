import Foundation
import Testing
@testable import ClaudePool

/// Drives `McpLoginFlow` and `McpSignInQueue` against a stand-in `claude` that behaves like
/// Claude Code 2.1.309's `claude mcp login --no-browser`: it refuses to run without a terminal,
/// prints the authorization link wrapped in terminal hyperlink escapes, then asks for the redirect
/// address until one from this sign-in arrives.
@MainActor
@Suite(.serialized)
struct McpLoginFlowTests {
    static let fakeClaude = #"""
    #!/bin/sh
    dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    if [ "$1 $2" = "mcp login" ]; then
      name="$3"
      case "$name" in
        "claude.ai "*)
          printf 'Visit this URL to authorize:\n  https://claude.ai/api/organizations/o/mcp/start-auth/s?x=1\n\n'
          printf 'Once authorized on claude.ai, the connector will be available the next time you start Claude Code.\n'
          exit 0 ;;
        nooauth)
          printf '"nooauth" doesn'"'"'t support OAuth login — it'"'"'s only available for HTTP and SSE servers.\n'
          exit 1 ;;
      esac
      if [ ! -t 0 ]; then echo "stdin isn't a terminal, so authentication can't be completed here."; exit 3; fi
      link='https://auth.example.com/authorize?state=s1&redirect_uri=http%3A%2F%2Flocalhost%3A5555%2Fcallback'
      printf 'Starting authentication for "%s"…\r\n' "$name"
      printf '[mcp-sdk] SEP-2352: stored OAuth credential has no issuer stamp.\r\n'
      printf 'Visit this URL to authorize:\r\n  \033]8;;%s\007\033[94m%s\033[39m\033]8;;\007\r\n\r\n' "$link" "$link"
      printf 'Waiting for authorization… (^C to cancel)\r\n'
      if [ -f "$dir/auto-callback" ]; then
        sleep 0.3; touch "$dir/mcp-$name"
        printf 'Authenticated with "%s". Its tools are now available in Claude Code.\r\n' "$name"; exit 0
      fi
      while true; do
        printf '\033[1G\033[0JOr paste the redirect URL here: '
        IFS= read -r line || exit 4
        case "$line" in
          *state=s1*)
            touch "$dir/mcp-$name"
            printf '\r\n\r\nAuthenticated with "%s". Its tools are now available in Claude Code.\r\n' "$name"; exit 0 ;;
          *) printf 'That doesn'"'"'t look like a redirect URL for this sign-in — paste the full address from the browser page this sign-in opened.\r\n' ;;
        esac
      done
    fi
    if [ "$1 $2" = "mcp get" ]; then
      if [ -f "$dir/mcp-$3" ]; then status='✔ Connected'; else status='! Needs authentication'; fi
      printf '%s:\n  Scope: User config (available in all your projects)\n  Status: %s\n  Type: http\n  URL: https://auth.example.com/mcp\n' "$3" "$status"
      exit 0
    fi
    exit 2
    """#

    struct Setup {
        let temp: TempDirectory
        let paths: Paths
        let binary: ClaudeBinary
        let profiles: [Profile]
    }

    private func setup(profiles count: Int = 1) throws -> Setup {
        let temp = try TempDirectory()
        let paths = temp.paths
        let bin = temp.file("bin/claude")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.fakeClaude.utf8).write(to: bin)
        chmod(bin.path, 0o755)
        let profiles = try (0..<count).map { index in
            let dir = paths.userHome.appendingPathComponent(".claude-p\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return Profile(id: UUID(), name: "P\(index)", slug: "p\(index)", configDir: dir.path, colorHex: "#0A84FF", isDefault: false,
                           trackingEnabled: false, originalStatusLine: nil, sortIndex: index, createdAt: Date())
        }
        return Setup(temp: temp, paths: paths, binary: ClaudeBinary(path: bin.path, source: .userOverride, version: "test"), profiles: profiles)
    }

    private func flow(_ setup: Setup, _ profile: Profile, server: String = "neon") -> McpLoginFlow {
        let service = McpService(home: setup.paths.userHome, loginShell: "/bin/zsh")
        let binary = setup.binary
        let environment = ChildEnvironment.claude(home: setup.paths.userHome, binary: binary, configDir: profile.configDirEnvironmentValue)
        return McpLoginFlow(profile: profile, serverName: server, binary: binary, home: setup.paths.userHome, environment: environment) { profile, name in
            try? await service.get(name, profile: profile, binary: binary)
        }
    }

    private func wait(_ flow: McpLoginFlow, timeout: Double = 8, until condition: (McpLoginFlow) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(flow), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func pastedAddressCompletesSignIn() async throws {
        let setup = try setup()
        let login = flow(setup, setup.profiles[0])
        login.start()
        await wait(login) { $0.phase == .waitingForAuthorization }
        #expect(login.phase == .waitingForAuthorization)
        // The link comes out of the terminal escapes intact and only once.
        #expect(login.authorizationURL?.absoluteString == "https://auth.example.com/authorize?state=s1&redirect_uri=http%3A%2F%2Flocalhost%3A5555%2Fcallback")
        login.submit(redirect: "  http://localhost:5555/callback?code=abc&state=s1 \n")
        await wait(login) { $0.phase.isFinished }
        #expect(login.phase == .succeeded)
        #expect(FileManager.default.fileExists(atPath: setup.profiles[0].configURL.appendingPathComponent("mcp-neon").path))
    }

    @Test func addressFromAnotherSignInIsRefusedAndCanBeRetried() async throws {
        let setup = try setup()
        let login = flow(setup, setup.profiles[0])
        login.start()
        await wait(login) { $0.phase == .waitingForAuthorization }
        login.submit(redirect: "http://localhost:5555/callback?code=abc&state=OLD")
        #expect(login.phase == .checkingRedirect)
        await wait(login) { $0.redirectError != nil }
        #expect(login.phase == .waitingForAuthorization)
        let message = login.redirectError ?? ""
        #expect(message.contains("doesn't look like a redirect URL"))
        // The pasted address (and its one-time code) is never repeated back.
        #expect(!message.contains("code=abc") && !message.contains("localhost"))

        login.submit(redirect: "http://localhost:5555/callback?code=abc&state=s1")
        await wait(login) { $0.phase.isFinished }
        #expect(login.phase == .succeeded)
        #expect(login.redirectError == nil)
    }

    @Test func implausibleAddressIsRejectedBeforeSending() async throws {
        let setup = try setup()
        let login = flow(setup, setup.profiles[0])
        login.start()
        await wait(login) { $0.phase == .waitingForAuthorization }
        login.submit(redirect: "abc#def")
        #expect(login.phase == .waitingForAuthorization)
        #expect(login.redirectError?.contains("http://localhost") == true)
        #expect(McpLoginFlow.isPlausibleRedirect("http://localhost:1/callback?code=x&state=y"))
        #expect(McpLoginFlow.isPlausibleRedirect("https://example.com/cb?error=access_denied"))
        #expect(!McpLoginFlow.isPlausibleRedirect("http://localhost:1/callback?state=y"))
        #expect(!McpLoginFlow.isPlausibleRedirect("http://localhost:1/callback?code=x y"))
        #expect(!McpLoginFlow.isPlausibleRedirect("javascript:alert(1)?code=1"))
        login.cancel()
    }

    @Test func browserCallbackCompletesWithoutPasting() async throws {
        let setup = try setup()
        try Data().write(to: setup.profiles[0].configURL.appendingPathComponent("auto-callback"))
        let login = flow(setup, setup.profiles[0])
        login.start()
        await wait(login) { $0.phase.isFinished }
        #expect(login.phase == .succeeded)
    }

    @Test func connectorFinishesOnClaudeAI() async throws {
        let setup = try setup()
        let login = flow(setup, setup.profiles[0], server: "claude.ai Mobbin")
        login.start()
        await wait(login) { $0.phase.isFinished }
        #expect(login.phase == .finishOnClaudeAI)
        #expect(login.authorizationURL?.host == "claude.ai")
    }

    @Test func serverWithoutOAuthFails() async throws {
        let setup = try setup()
        let login = flow(setup, setup.profiles[0], server: "nooauth")
        login.start()
        await wait(login) { $0.phase.isFinished }
        guard case let .failed(message) = login.phase else { Issue.record("phase \(login.phase)"); return }
        #expect(message.contains("doesn't support OAuth login"))
    }

    @Test func cancelStopsTheProcess() async throws {
        let setup = try setup()
        let login = flow(setup, setup.profiles[0])
        login.start()
        await wait(login) { $0.phase == .waitingForAuthorization }
        await login.stop()
        #expect(login.phase == .cancelled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(login.phase == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: setup.profiles[0].configURL.appendingPathComponent("mcp-neon").path))
    }

    @Test func outputParsing() {
        let raw = "Starting…\r\nVisit this URL to authorize:\r\n  \u{1B}]8;;https://a.example/x?y=1\u{07}\u{1B}[94mhttps://a.example/x?y=1\u{1B}[39m\u{1B}]8;;\u{07}\r\n\r\n\u{1B}[1G\u{1B}[0JOr paste the redirect URL here: \u{1B}[33G"
        let plain = McpLoginFlow.plainText(raw)
        #expect(!plain.contains("\u{1B}"))
        #expect(plain.components(separatedBy: "https://a.example/x?y=1").count == 2)
        #expect(McpLoginFlow.authorizationURL(in: plain)?.absoluteString == "https://a.example/x?y=1")
        #expect(McpLoginFlow.authorizationURL(in: "Visit this URL to authorize:\n  http://evil.example/a") == nil)
        #expect(McpLoginFlow.authorizationURL(in: "Visit this URL to authorize:\n  http://127.0.0.1:4/authorize?a=1")?.port == 4)
        #expect(McpLoginFlow.messages(in: "[mcp-sdk] notice\nWaiting for authorization…\nCouldn't reach https://x.example/token?a=1 now\n")
                == ["Couldn't reach <link> now"])
    }

    // MARK: Queue

    @Test func queueSignsInEachProfileInTurn() async throws {
        let setup = try setup(profiles: 3)
        for profile in setup.profiles {
            try Data().write(to: profile.configURL.appendingPathComponent("auto-callback"))
        }
        McpSignInQueue.advanceDelay = .milliseconds(10)
        var finished: [String] = []
        let queue = McpSignInQueue(steps: setup.profiles.map { McpSignInStep(profile: $0, serverName: "neon") },
                                   makeFlow: { self.flow(setup, $0.profile, server: $0.serverName) },
                                   onStepFinished: { step, _ in finished.append(step.profile.name) })
        queue.start()
        let deadline = Date().addingTimeInterval(15)
        while !queue.isComplete, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(queue.isComplete)
        #expect(queue.signedInCount == 3)
        #expect(finished == ["P0", "P1", "P2"])
        #expect(queue.singleServerName == "neon")
    }

    @Test func queueSkipMovesOnAndStopsTheSignIn() async throws {
        let setup = try setup(profiles: 2)
        try Data().write(to: setup.profiles[1].configURL.appendingPathComponent("auto-callback"))
        McpSignInQueue.advanceDelay = .milliseconds(10)
        let steps = setup.profiles.map { McpSignInStep(profile: $0, serverName: "neon") }
        let queue = McpSignInQueue(steps: steps, makeFlow: { self.flow(setup, $0.profile, server: $0.serverName) })
        queue.start()
        let first = try #require(queue.flow)
        await wait(first) { $0.phase == .waitingForAuthorization }
        queue.skip()
        let deadline = Date().addingTimeInterval(10)
        while !queue.isComplete, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(first.phase == .cancelled)
        #expect(queue.outcome(of: steps[0]) == .skipped)
        #expect(queue.outcome(of: steps[1]) == .signedIn)
        #expect(queue.signedInCount == 1)
    }
}
