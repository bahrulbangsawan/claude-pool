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

/// Opens Terminal.app running `claude` for a profile. Uses a `.command` file opened through
/// NSWorkspace, so no Apple Events permission is needed.
struct TerminalLauncher: Sendable {
    static let terminalBundleID = "com.apple.Terminal"
    static let scriptLifetime: TimeInterval = 24 * 60 * 60

    let paths: Paths

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

    @MainActor
    func launch(_ profile: Profile, workingDirectory: String, claudePath: String, arguments: [String] = []) async throws {
        let script = try writeScript(for: profile, workingDirectory: workingDirectory, claudePath: claudePath, arguments: arguments)
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
