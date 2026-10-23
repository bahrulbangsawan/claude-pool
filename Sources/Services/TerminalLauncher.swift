import AppKit
import Foundation

enum TerminalLauncherError: Error, LocalizedError {
    case terminalMissing

    var errorDescription: String? {
        switch self {
        case .terminalMissing: "Terminal.app could not be found."
        }
    }
}

/// Opens Terminal.app, or a herdr tab, running `claude` for a profile. Terminal gets a `.command`
/// file opened through NSWorkspace, so no Apple Events permission is needed; herdr runs the same
/// file in a new tab through its CLI.
struct TerminalLauncher: Sendable {
    static let terminalBundleID = "com.apple.Terminal"
    static let scriptLifetime: TimeInterval = 24 * 60 * 60

    let paths: Paths
    var herdr: HerdrClient { HerdrClient(home: paths.userHome) }

    /// The launcher script. Every interpolated value goes through `ShellQuote`.
    static func script(profileName: String, configDir: String?, workingDirectory: String, claudePath: String, arguments: [String] = []) -> String {
        let envLine = configDir.map { "export CLAUDE_CONFIG_DIR=\(ShellQuote.quote($0))" } ?? "unset CLAUDE_CONFIG_DIR"
        let command = ([claudePath] + arguments).map(ShellQuote.quote).joined(separator: " ")
        return """
        #!/bin/zsh
        printf '\\e]0;Claude Pool — %s\\a' \(ShellQuote.quote(profileName))
        \(envLine)
        cd \(ShellQuote.quote(workingDirectory)) 2>/dev/null || cd "$HOME"
        \(command)
        exec /bin/zsh -il

        """
    }

    func writeScript(for profile: Profile, workingDirectory: String, claudePath: String, arguments: [String] = []) throws -> URL {
        try AtomicFile.ensureDirectory(paths.caches, permissions: 0o700)
        let url = paths.caches.appendingPathComponent("launch-\(UUID().uuidString).command")
        let text = Self.script(
            profileName: profile.name,
            configDir: profile.configDirEnvironmentValue,
            workingDirectory: paths.expandTilde(workingDirectory),
            claudePath: claudePath,
            arguments: arguments
        )
        try AtomicFile.write(Data(text.utf8), to: url, permissions: 0o700)
        return url
    }

    /// Starts herdr in Terminal; its first client also starts the herdr server.
    static func herdrScript(herdrPath: String, workingDirectory: String) -> String {
        """
        #!/bin/zsh
        cd \(ShellQuote.quote(workingDirectory)) 2>/dev/null || cd "$HOME"
        \(ShellQuote.quote(herdrPath))
        exec /bin/zsh -il

        """
    }

    func writeHerdrScript(herdrPath: String, workingDirectory: String) throws -> URL {
        try AtomicFile.ensureDirectory(paths.caches, permissions: 0o700)
        let url = paths.caches.appendingPathComponent("launch-herdr-\(UUID().uuidString).command")
        let text = Self.herdrScript(herdrPath: herdrPath, workingDirectory: paths.expandTilde(workingDirectory))
        try AtomicFile.write(Data(text.utf8), to: url, permissions: 0o700)
        return url
    }

    @MainActor
    func launch(_ profile: Profile, workingDirectory: String, claudePath: String, arguments: [String] = [], in host: TerminalHost = .terminal) async throws {
        let script = try writeScript(for: profile, workingDirectory: workingDirectory, claudePath: claudePath, arguments: arguments)
        guard host == .herdr else { return try await openInTerminal(script) }
        let herdr = herdr
        guard let binary = herdr.binary else { throw HerdrError.notInstalled }
        let directory = paths.expandTilde(workingDirectory)
        do {
            try await herdr.openTab(running: script, label: profile.name, workingDirectory: directory)
        } catch HerdrError.notRunning {
            try await openInTerminal(try writeHerdrScript(herdrPath: binary.path, workingDirectory: workingDirectory))
            guard await herdr.waitForServer() else { throw HerdrError.startTimedOut }
            try await herdr.openTab(running: script, label: profile.name, workingDirectory: directory)
        }
        HerdrClient.hostApplication()?.activate()
    }

    @MainActor
    private func openInTerminal(_ script: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.terminalBundleID) else {
            throw TerminalLauncherError.terminalMissing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
    }

    /// Deletes launcher scripts older than 24 hours.
    func cleanUpOldScripts(now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: paths.caches, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items where item.lastPathComponent.hasPrefix("launch-") && item.pathExtension == "command" {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > Self.scriptLifetime {
                try? fm.removeItem(at: item)
            }
        }
    }
}
