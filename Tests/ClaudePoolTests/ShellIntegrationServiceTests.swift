import Foundation
import Testing
@testable import ClaudePool

@Suite struct ShellIntegrationServiceTests {
    /// The block exactly as specified.
    static let expectedSnippet = """
    # >>> claude-pool >>>
    # Managed by Claude Pool. Remove this block or use the app's Uninstall button.
    claude() {
      if [[ -z "${CLAUDE_CONFIG_DIR-}" ]]; then
        local _cp_dir
        _cp_dir="$(cat "$HOME/.claude-pool/active" 2>/dev/null)"
        if [[ -n "$_cp_dir" && -d "$_cp_dir" ]]; then
          CLAUDE_CONFIG_DIR="$_cp_dir" command claude "$@"
          return
        fi
      fi
      command claude "$@"
    }
    # <<< claude-pool <<<

    """

    let temp: TempDirectory
    let service: ShellIntegrationService
    var zshrc: URL { temp.paths.userHome.appendingPathComponent(".zshrc") }

    init() throws {
        temp = try TempDirectory()
        try FileManager.default.createDirectory(at: temp.paths.userHome, withIntermediateDirectories: true)
        service = ShellIntegrationService(home: temp.paths.userHome, loginShell: "/bin/zsh")
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temp.paths.userHome.path)
            .filter { $0.hasPrefix(".zshrc.claude-pool.bak-") }
    }

    @Test func snippetMatchesSpecExactly() {
        #expect(ShellIntegrationService.snippet == Self.expectedSnippet)
    }

    @Test func snippetIsValidZshAndBash() throws {
        let file = try temp.write(ShellIntegrationService.snippet, to: "snippet.sh")
        #expect(try runProcess(URL(fileURLWithPath: "/bin/zsh"), ["-n", file.path], environment: [:]).status == 0)
        #expect(try runProcess(URL(fileURLWithPath: "/bin/bash"), ["-n", file.path], environment: [:]).status == 0)
    }

    @Test func installIntoMissingFile() throws {
        #expect(service.status() == .notInstalled)
        let backup = try service.install()
        #expect(backup == nil)
        #expect(readText(zshrc) == Self.expectedSnippet)
        #expect(service.status() == .installed)
    }

    @Test func installIntoEmptyFileMakesBackup() throws {
        try Data().write(to: zshrc)
        let backup = try #require(try service.install())
        #expect(try Data(contentsOf: backup).isEmpty)
        #expect(readText(zshrc) == Self.expectedSnippet)
    }

    @Test func installIntoExistingFileAppendsAndBacksUp() throws {
        let original = "export PATH=\"$HOME/bin:$PATH\"\nalias ll='ls -l'\n"
        try Data(original.utf8).write(to: zshrc)
        let backup = try #require(try service.install(now: Date(timeIntervalSince1970: 0)))
        #expect(backup.lastPathComponent.hasPrefix(".zshrc.claude-pool.bak-"))
        #expect(readText(backup) == original)
        #expect(permissions(of: backup) == 0o600)
        #expect(readText(zshrc) == original + Self.expectedSnippet)
    }

    @Test func installAddsNewlineWhenMissing() throws {
        try Data("alias x=y".utf8).write(to: zshrc)
        try service.install()
        #expect(readText(zshrc) == "alias x=y\n" + Self.expectedSnippet)
    }

    @Test func installIsIdempotent() throws {
        try Data("a\n".utf8).write(to: zshrc)
        try service.install()
        let once = readText(zshrc)
        try service.install()
        try service.install()
        #expect(readText(zshrc) == once)
        #expect(once?.components(separatedBy: ShellIntegrationService.beginMarker).count == 2)
    }

    @Test func outdatedBlockIsReplacedInPlace() throws {
        let old = "# >>> claude-pool >>>\nclaude() { command claude \"$@\"; }\n# <<< claude-pool <<<\n"
        try Data(("before\n" + old + "after\n").utf8).write(to: zshrc)
        #expect(service.status() == .outdated)
        try service.install()
        #expect(readText(zshrc) == "before\n" + Self.expectedSnippet + "after\n")
        #expect(service.status() == .installed)
    }

    @Test func uninstallLeavesOtherBytesIdentical() throws {
        let head = "# my config\nexport A=1\n\n"
        let tail = "\nsource ~/.local.zsh\n# end without newline"
        try Data((head + Self.expectedSnippet + tail).utf8).write(to: zshrc)
        let backup = try #require(try service.uninstall())
        #expect(readText(zshrc) == head + tail)
        #expect(readText(backup) == head + Self.expectedSnippet + tail)
        #expect(service.status() == .notInstalled)
    }

    @Test func installThenUninstallRestoresOriginal() throws {
        let original = "export A=1\n"
        try Data(original.utf8).write(to: zshrc)
        try service.install(now: Date(timeIntervalSince1970: 0))
        try service.uninstall(now: Date(timeIntervalSince1970: 0))
        #expect(readText(zshrc) == original)
        #expect(try backups().count == 2)
    }

    @Test func uninstallWithoutBlockChangesNothing() throws {
        try Data("x\n".utf8).write(to: zshrc)
        #expect(try service.uninstall() == nil)
        #expect(readText(zshrc) == "x\n")
        #expect(try backups().isEmpty)
    }

    @Test func preservesPermissionsAndWritesThroughSymlinks() throws {
        let real = try temp.write("export B=2\n", to: "dotfiles/zshrc")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: zshrc, withDestinationURL: real)
        try service.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path) == real.path)
        #expect(readText(real) == "export B=2\n" + Self.expectedSnippet)
        #expect(permissions(of: real) == 0o640)
    }

    @Test func refusesUnbalancedMarkers() throws {
        try Data("# >>> claude-pool >>>\nstuff\n".utf8).write(to: zshrc)
        #expect(throws: ShellIntegrationError.self) { try service.install() }
    }

    @Test func targetDependsOnLoginShell() {
        let home = temp.paths.userHome
        #expect(ShellIntegrationService(home: home, loginShell: "/bin/zsh").targetFile?.lastPathComponent == ".zshrc")
        #expect(ShellIntegrationService(home: home, loginShell: "/opt/homebrew/bin/bash").targetFile?.lastPathComponent == ".bash_profile")
        let fish = ShellIntegrationService(home: home, loginShell: "/opt/homebrew/bin/fish")
        #expect(fish.targetFile == nil)
        #expect(fish.status() == .unsupportedShell("fish"))
        #expect(throws: ShellIntegrationError.self) { try fish.install() }
    }

    /// End to end: the installed function honours the pointer and an explicit variable.
    @Test func installedFunctionUsesPointer() throws {
        try service.install()
        let bin = temp.file("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = try temp.write("#!/bin/sh\nprintf '%s' \"${CLAUDE_CONFIG_DIR-UNSET}\"\n", to: "bin/claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let workDir = temp.paths.userHome.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let pointer = PointerFileService(pool: PoolPaths(home: temp.paths.userHome.appendingPathComponent(".claude-pool")))

        func run(_ command: String) throws -> String {
            try runProcess(
                URL(fileURLWithPath: "/bin/zsh"), ["-c", "source \(ShellQuote.quote(zshrc.path)); \(command)"],
                environment: ["HOME": temp.paths.userHome.path, "PATH": "\(bin.path):/usr/bin:/bin"]
            ).stdoutText
        }

        try pointer.write(nil)
        #expect(try run("claude") == "UNSET")
        try pointer.write(workDir.path)
        #expect(try run("claude") == workDir.path)
        #expect(try run("CLAUDE_CONFIG_DIR=/explicit claude") == "/explicit")
        try pointer.write(temp.file("missing-dir").path)
        #expect(try run("claude") == "UNSET")
    }
}
