import Foundation
import Testing
@testable import ClaudePool

/// Drives `LoginFlow` against a stand-in `claude` that behaves like Claude Code 2.1.296 without a
/// TTY: prints the manual URL, asks `$BROWSER` to open the callback URL, then reads a code on stdin.
@MainActor
@Suite(.serialized)
struct LoginFlowTests {
    static let fakeClaude = #"""
    #!/bin/sh
    dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    if [ "$1 $2" = "auth status" ]; then
      if [ -f "$dir/signed-in" ]; then
        printf '{"loggedIn":true,"authMethod":"claude.ai","configDirectory":"%s","email":"new@example.com","orgId":"org-1","subscriptionType":"max"}\n' "$dir"
        exit 0
      fi
      printf '{"loggedIn":false,"authMethod":"none"}\n'; exit 1
    fi
    if [ "$1 $2" = "auth login" ]; then
      echo "Opening browser to sign in…"
      [ -n "$BROWSER" ] && "$BROWSER" "https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1234%2Fcallback&state=s"
      echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=s"
      printf 'Paste code here if prompted > '
      if [ -f "$dir/auto-callback" ]; then sleep 0.3; touch "$dir/signed-in"; echo "Login successful."; exit 0; fi
      read code
      if [ "$code" = "good#state" ]; then touch "$dir/signed-in"; echo "Login successful."; exit 0; fi
      echo "OAuth login failed: Invalid code. Please make sure the full code was copied." >&2
      exit 1
    fi
    exit 2
    """#

    private func setup() throws -> (TempDirectory, Paths, Profile, ClaudeBinary) {
        let temp = try TempDirectory()
        let paths = temp.paths
        let bin = temp.file("bin/claude")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.fakeClaude.utf8).write(to: bin)
        chmod(bin.path, 0o755)
        let dir = paths.userHome.appendingPathComponent(".claude-new")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = Profile(id: UUID(), name: "New", slug: "new", configDir: dir.path, colorHex: "#0A84FF", isDefault: false,
                              trackingEnabled: false, originalStatusLine: nil, sortIndex: 1, createdAt: Date())
        return (temp, paths, profile, ClaudeBinary(path: bin.path, source: .userOverride, version: "test"))
    }

    private func flow(_ paths: Paths, _ profile: Profile, _ binary: ClaudeBinary) -> LoginFlow {
        let service = AuthStatusService(home: paths.userHome)
        return LoginFlow(profile: profile, binary: binary, paths: paths, previousIdentity: nil) { profile in
            try? await service.check(profile, binary: binary)
        }
    }

    private func wait(_ flow: LoginFlow, timeout: Double = 8, until condition: (LoginFlow.Phase) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(flow.phase), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func pastedCodeCompletesSignIn() async throws {
        let (temp, paths, profile, binary) = try setup()
        _ = temp
        let login = flow(paths, profile, binary)
        login.start()
        await wait(login) { $0 == .waitingForAuthorization }
        await wait(login, timeout: 2) { _ in login.callbackURL != nil && login.manualURL != nil }
        #expect(login.phase == .waitingForAuthorization)
        #expect(login.manualURL?.absoluteString.contains("platform.claude.com") == true)
        #expect(login.callbackURL?.absoluteString.contains("localhost") == true)
        login.submit(code: "  good#state \n")
        await wait(login) { $0.isFinished }
        guard case let .succeeded(status) = login.phase else { Issue.record("phase \(login.phase)"); return }
        #expect(status.email == "new@example.com")
        #expect(status.orgId == "org-1")
        // The capture folder (with the recorded URL) is removed afterwards.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: paths.caches.path))?.filter { $0.hasPrefix("login-") } ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func browserCallbackCompletesWithoutACode() async throws {
        let (temp, paths, profile, binary) = try setup()
        _ = temp
        try Data().write(to: profile.configURL.appendingPathComponent("auto-callback"))
        let login = flow(paths, profile, binary)
        login.start()
        await wait(login) { $0.isFinished }
        guard case .succeeded = login.phase else { Issue.record("phase \(login.phase)"); return }
    }

    @Test func invalidCodeFailsAndCanBeRetried() async throws {
        let (temp, paths, profile, binary) = try setup()
        _ = temp
        let login = flow(paths, profile, binary)
        login.start()
        await wait(login) { $0 == .waitingForAuthorization }
        login.submit(code: "wrong#state")
        await wait(login) { $0.isFinished }
        guard case let .failed(message) = login.phase else { Issue.record("phase \(login.phase)"); return }
        #expect(message.contains("rejected"))
        #expect(!message.contains("wrong#state"))

        login.start()
        await wait(login) { $0 == .waitingForAuthorization }
        login.submit(code: "good#state")
        await wait(login) { $0.isFinished }
        guard case .succeeded = login.phase else { Issue.record("phase \(login.phase)"); return }
    }

    @Test func malformedCodeIsRejectedBeforeSending() async throws {
        let (temp, paths, profile, binary) = try setup()
        _ = temp
        let login = flow(paths, profile, binary)
        login.start()
        await wait(login) { $0 == .waitingForAuthorization }
        login.submit(code: "no-hash-here")
        guard case let .failed(message) = login.phase else { Issue.record("phase \(login.phase)"); return }
        #expect(message.contains("#"))
        #expect(!LoginFlow.isPlausibleCode("a#"))
        #expect(!LoginFlow.isPlausibleCode("a b#c"))
        #expect(LoginFlow.isPlausibleCode("abc#def"))
    }

    @Test func cancelStopsTheProcess() async throws {
        let (temp, paths, profile, binary) = try setup()
        _ = temp
        let login = flow(paths, profile, binary)
        login.start()
        await wait(login) { $0 == .waitingForAuthorization }
        login.cancel()
        #expect(login.phase == .cancelled)
        try await Task.sleep(for: .milliseconds(500))
        #expect(login.phase == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: profile.configURL.appendingPathComponent("signed-in").path))
    }

    @Test func outputParsing() {
        let text = "Opening browser to sign in…\nIf the browser didn't open, visit: https://claude.com/x?a=1&b=2\nPaste code here if prompted > "
        #expect(LoginFlow.manualURL(in: text)?.absoluteString == "https://claude.com/x?a=1&b=2")
        #expect(LoginFlow.manualURL(in: "visit: http://insecure.example") == nil)
        #expect(LoginFlow.failureReason(in: "Paste code here if prompted > \nOAuth login failed: token endpoint https://x.y/z said no\n")
                == "OAuth login failed: token endpoint <link> said no")
    }
}
