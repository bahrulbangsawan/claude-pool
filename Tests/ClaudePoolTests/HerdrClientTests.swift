import Foundation
import Testing
@testable import ClaudePool

@Suite struct HerdrClientTests {
    /// A fake `herdr` that logs each call's arguments as `[a][b]…` and replies like the real CLI:
    /// `tab create` prints the created tab, `pane run` prints nothing.
    private func fakeHerdr(in temp: TempDirectory, tabCreateReply: String, exitCode: Int = 0) throws -> URL {
        let script = """
        #!/bin/sh
        for a in "$@"; do printf '[%s]' "$a"; done >> "$HOME/herdr.log"
        echo >> "$HOME/herdr.log"
        if [ "$1 $2" = "tab create" ]; then
          printf '%s\\n' \(ShellQuote.quote(tabCreateReply))
          exit \(exitCode)
        fi
        if [ "$1 $2" = "status --json" ]; then
          if [ -f "$HOME/server-running" ]; then running=true; else running=false; fi
          printf '{"client":{"version":"0.8.2"},"server":{"status":"x","running":%s}}\\n' "$running"
        fi
        exit 0

        """
        let url = try temp.write(script, to: "bin/herdr")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func client(_ temp: TempDirectory, binary: URL?) -> HerdrClient {
        var client = HerdrClient(home: temp.url)
        client.candidatePaths = binary.map { [$0.path] } ?? []
        return client
    }

    @Test func opensFocusedTabThenRunsQuotedScript() async throws {
        let temp = try TempDirectory()
        let created = #"{"id":"cli:tab:create","result":{"type":"tab_created","tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9","cwd":"/x"}}}"#
        let herdr = try fakeHerdr(in: temp, tabCreateReply: created)
        let workDir = temp.file("work dir")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        try await client(temp, binary: herdr).openTab(
            running: URL(fileURLWithPath: "/tmp/a b/launch-1.command"), label: "Bob's work", workingDirectory: workDir.path
        )

        let calls = readText(temp.file("herdr.log"))?.split(separator: "\n").map(String.init)
        #expect(calls == [
            "[tab][create][--label][Bob's work][--focus][--cwd][\(workDir.path)]",
            "[pane][run][w1:p9]['/tmp/a b/launch-1.command']",
        ])
    }

    @Test func missingWorkingDirectoryIsLeftToHerdr() async throws {
        let temp = try TempDirectory()
        let created = #"{"result":{"type":"tab_created","root_pane":{"pane_id":"w2:p1"}}}"#
        let herdr = try fakeHerdr(in: temp, tabCreateReply: created)

        try await client(temp, binary: herdr).openTab(
            running: URL(fileURLWithPath: "/tmp/launch.command"), label: "Default", workingDirectory: temp.file("gone").path
        )

        #expect(readText(temp.file("herdr.log"))?.hasPrefix("[tab][create][--label][Default][--focus]\n") == true)
    }

    @Test func serverNotRunningIsReported() async throws {
        let temp = try TempDirectory()
        let reply = #"{"id":"cli:tab:create","error":{"code":"server_not_running","message":"no herdr server is running"}}"#
        let herdr = try fakeHerdr(in: temp, tabCreateReply: reply, exitCode: 1)

        await #expect(throws: HerdrError.notRunning) {
            try await client(temp, binary: herdr).openTab(running: URL(fileURLWithPath: "/tmp/l.command"), label: "A", workingDirectory: "/")
        }
        // Nothing is typed anywhere when the tab could not be created.
        #expect(readText(temp.file("herdr.log"))?.contains("[pane][run]") == false)
    }

    @Test func otherErrorsCarryHerdrsMessage() async throws {
        let temp = try TempDirectory()
        let reply = #"{"error":{"code":"workspace_not_found","message":"workspace w9 not found"}}"#
        let herdr = try fakeHerdr(in: temp, tabCreateReply: reply, exitCode: 1)

        await #expect(throws: HerdrError.failed("workspace w9 not found")) {
            try await client(temp, binary: herdr).openTab(running: URL(fileURLWithPath: "/tmp/l.command"), label: "A", workingDirectory: "/")
        }
    }

    @Test func replyWithoutPaneIsAnError() async throws {
        let temp = try TempDirectory()
        let herdr = try fakeHerdr(in: temp, tabCreateReply: #"{"result":{"type":"ok"}}"#)

        await #expect(throws: HerdrError.self) {
            try await client(temp, binary: herdr).openTab(running: URL(fileURLWithPath: "/tmp/l.command"), label: "A", workingDirectory: "/")
        }
        #expect(readText(temp.file("herdr.log"))?.contains("[pane][run]") == false)
    }

    @Test func missingBinaryIsReported() async throws {
        let temp = try TempDirectory()
        await #expect(throws: HerdrError.notInstalled) {
            try await client(temp, binary: nil).openTab(running: URL(fileURLWithPath: "/tmp/l.command"), label: "A", workingDirectory: "/")
        }
    }

    @Test func serverStatusComesFromHerdrStatus() async throws {
        let temp = try TempDirectory()
        let herdr = client(temp, binary: try fakeHerdr(in: temp, tabCreateReply: "{}"))
        #expect(await herdr.serverIsRunning() == false)
        #expect(await herdr.waitForServer(timeout: 0.6) == false)

        try temp.write("", to: "server-running")
        #expect(await herdr.serverIsRunning())
        #expect(await herdr.waitForServer(timeout: 5))
    }

    // MARK: Install

    /// An installer that behaves like herdr.dev/install.sh: binary into $HOME/.local/bin, errors on stderr.
    private func installer(in temp: TempDirectory, _ body: String) throws -> String {
        try temp.write("#!/bin/sh\nset -eu\n\(body)\n", to: "installer/install.sh").absoluteString
    }

    @Test func installRunsTheInstallerAndFindsTheBinary() async throws {
        let temp = try TempDirectory()
        let url = try installer(in: temp, #"""
        mkdir -p "$HOME/.local/bin"
        printf '#!/bin/sh\necho herdr 9.9.9\n' > "$HOME/.local/bin/herdr"
        chmod +x "$HOME/.local/bin/herdr"
        printf '  \033[32m>\033[0m installed herdr\n'
        """#)
        var herdr = HerdrClient(home: temp.url)
        herdr.candidatePaths = [temp.file(".local/bin/herdr").path]
        #expect(herdr.binary == nil)

        let installed = try await herdr.install(from: url)
        #expect(installed.path == temp.file(".local/bin/herdr").path)
        #expect(herdr.binary != nil)
    }

    @Test func installFailureShowsTheInstallersMessage() async throws {
        let temp = try TempDirectory()
        let url = try installer(in: temp, #"""
        printf '  \033[32m>\033[0m fetching latest release manifest...\n'
        printf '  \033[31m✗\033[0m %s\n' "can't reach https://herdr.dev/latest.json" >&2
        exit 1
        """#)
        await #expect(throws: HerdrError.installFailed("can't reach https://herdr.dev/latest.json")) {
            try await client(temp, binary: nil).install(from: url)
        }
    }

    @Test func installThatLeavesNoBinaryFails() async throws {
        let temp = try TempDirectory()
        let url = try installer(in: temp, "echo done")
        var herdr = HerdrClient(home: temp.url)
        herdr.candidatePaths = [temp.file(".local/bin/herdr").path]
        await #expect(throws: HerdrError.self) { try await herdr.install(from: url) }
    }

    @Test func unreachableInstallerFails() async throws {
        let temp = try TempDirectory()
        await #expect(throws: HerdrError.self) {
            try await client(temp, binary: nil).install(from: temp.file("missing/install.sh").absoluteString)
        }
    }

    @Test func settingDefaultsToTerminalAndRoundTrips() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultWorkingDirectory":"~/code"}"#.utf8))
        #expect(old.terminalHost == .terminal)

        var settings = AppSettings()
        settings.terminalHost = .herdr
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.terminalHost == .herdr)
    }
}
