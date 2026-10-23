import Foundation
import Testing
@testable import ClaudePool

@Suite struct ShellQuoteTests {
    static let samples = [
        "",
        "plain",
        "with spaces  and\ttabs",
        "it's",
        "''",
        "$HOME and ${PATH} and $(whoami)",
        "`touch /tmp/claude-pool-should-not-exist`",
        "line one\nline two\n",
        "back\\slash \"double\"",
        "ünïcødé 日本語 🚀 — dash",
        "!event ; rm -rf / & | > <",
    ]

    @Test func wrapsAndEscapesSingleQuotes() {
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("abc") == "'abc'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("$x `y`") == "'$x `y`'")
    }

    @Test(arguments: samples)
    func roundTripsThroughZsh(_ value: String) throws {
        let result = try runProcess(
            URL(fileURLWithPath: "/bin/zsh"),
            ["-f", "-c", "print -r -- \(ShellQuote.quote(value))"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(result.status == 0)
        #expect(result.stdoutText == value + "\n")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/claude-pool-should-not-exist"))
    }
}

@Suite struct TerminalLauncherTests {
    @Test func defaultProfileUnsetsConfigDir() {
        let script = TerminalLauncher.script(profileName: "Default", configDir: nil, workingDirectory: "/Users/x", claudePath: "/opt/homebrew/bin/claude")
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("\nunset CLAUDE_CONFIG_DIR\n"))
        #expect(!script.contains("export CLAUDE_CONFIG_DIR"))
        #expect(script.contains("\n'/opt/homebrew/bin/claude'\n"))
        #expect(script.hasSuffix("exec /bin/zsh -il\n"))
    }

    @Test func nonDefaultProfileExportsQuotedDir() {
        let script = TerminalLauncher.script(profileName: "Bob's work", configDir: "/Users/x/.claude-bob's", workingDirectory: "/tmp/a b", claudePath: "/x/claude")
        #expect(script.contains("export CLAUDE_CONFIG_DIR='/Users/x/.claude-bob'\\''s'"))
        #expect(script.contains("printf '\\e]0;Claude Pool — %s\\a' 'Bob'\\''s work'"))
        #expect(script.contains("cd '/tmp/a b' 2>/dev/null || cd \"$HOME\""))
    }

    /// Executes the generated script with a fake `claude` to prove quoting and environment.
    @Test func scriptRunsWithHostileValues() throws {
        let temp = try TempDirectory()
        let workDir = temp.file("work dir 'q' $x")
        let configDir = temp.file("cfg `dir` $(id)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let fakeClaude = try temp.write("#!/bin/sh\nprintf 'DIR=%s\\nPWD=%s\\n' \"${CLAUDE_CONFIG_DIR-UNSET}\" \"$(pwd)\"\n", to: "bin/fake claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        for configValue in [configDir.path, nil] as [String?] {
            let script = TerminalLauncher.script(profileName: "Name 'x' $(id)", configDir: configValue, workingDirectory: workDir.path, claudePath: fakeClaude.path)
            let scriptURL = try temp.write(script, to: "launch.command")
            let result = try runProcess(
                URL(fileURLWithPath: "/bin/zsh"), [scriptURL.path],
                // ZDOTDIR/HOME point at the temp dir so no real startup files load; stdin is empty
                // so the trailing interactive shell exits immediately.
                environment: ["HOME": temp.url.path, "ZDOTDIR": temp.url.path, "PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/should/be/replaced"]
            )
            // The title escape sequence has no newline, so match on substrings.
            #expect(result.stdoutText.contains("DIR=\(configValue ?? "UNSET")\n"))
            #expect(result.stdoutText.contains("\nPWD=\(workDir.path)\n"))
            #expect(result.stdoutText.hasPrefix("\u{1B}]0;Claude Pool — Name 'x' $(id)\u{07}"))
        }
    }

    @Test func herdrScriptQuotesPathsAndKeepsAShell() {
        let script = TerminalLauncher.herdrScript(herdrPath: "/Users/x/my 'bin'/herdr", workingDirectory: "/tmp/a b")
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("\ncd '/tmp/a b' 2>/dev/null || cd \"$HOME\"\n"))
        #expect(script.contains("\n'/Users/x/my '\\''bin'\\''/herdr'\n"))
        #expect(script.hasSuffix("exec /bin/zsh -il\n"))
    }

    @Test func cleanupRemovesOnlyOldScripts() throws {
        let temp = try TempDirectory()
        let launcher = TerminalLauncher(paths: temp.paths)
        try FileManager.default.createDirectory(at: temp.paths.caches, withIntermediateDirectories: true)
        let old = temp.paths.caches.appendingPathComponent("launch-old.command")
        let fresh = temp.paths.caches.appendingPathComponent("launch-new.command")
        let other = temp.paths.caches.appendingPathComponent("keep.txt")
        for url in [old, fresh, other] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: other.path)
        launcher.cleanUpOldScripts()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func writtenScriptIsOwnerExecutable() throws {
        let temp = try TempDirectory()
        let launcher = TerminalLauncher(paths: temp.paths)
        let profile = Profile.makeDefault(home: temp.paths.userHome)
        let url = try launcher.writeScript(for: profile, workingDirectory: "~", claudePath: "/x/claude")
        #expect(permissions(of: url) == 0o700)
        #expect(url.pathExtension == "command")
        #expect(readText(url)?.contains("cd '\(temp.paths.userHome.path)'") == true)
    }
}
