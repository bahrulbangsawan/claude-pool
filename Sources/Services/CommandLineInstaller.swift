import Foundation

enum CommandLineInstallState: Equatable, Sendable {
    /// The link at this path starts this copy of Claude Pool.
    case installed(String)
    /// The link at this path starts another copy of Claude Pool (or one that was moved or deleted).
    case otherCopy(String)
    case notInstalled
}

enum CommandLineInstallError: Error, LocalizedError, Equatable {
    case occupied(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .occupied(path): "\(path) already exists and isn't Claude Pool's. Remove or rename it, then try again."
        case let .failed(message): "Couldn't change the claude-pool command: \(message)"
        case .cancelled: "Cancelled."
        }
    }
}

/// Puts `claude-pool` on the PATH as a symbolic link to the app's executable, which runs
/// `CommandLineTool` when started under that name. An update replaces the app in place, so the
/// link keeps working.
struct CommandLineInstaller: Sendable {
    static let systemFolder = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

    let home: URL
    /// The link's target: the app's executable.
    let executable: URL
    let loginShell: String
    /// Its own runner: the password prompt can stay open for minutes without holding up sign-in checks.
    var runner = ProcessRunner(maxConcurrent: 1)
    /// Where a link is looked for and made, best first. The first two are usually writable without
    /// an administrator password; /usr/local/bin is on every Mac's default PATH.
    var folders: [URL]

    init(home: URL, executable: URL, loginShell: String) {
        self.home = home
        self.executable = executable
        self.loginShell = loginShell
        folders = [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            Self.systemFolder,
        ]
    }

    func link(in folder: URL) -> URL {
        folder.appendingPathComponent(CommandLineTool.commandName)
    }

    func state() -> CommandLineInstallState {
        var other: String?
        for folder in folders {
            let link = link(in: folder)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { continue }
            if Self.canonical(target, relativeTo: folder) == Self.canonical(executable.path, relativeTo: folder) { return .installed(link.path) }
            if Self.isClaudePool(target) { other = other ?? link.path }
        }
        return other.map(CommandLineInstallState.otherCopy) ?? .notInstalled
    }

    /// Replaces an existing Claude Pool link where it is; otherwise links in the first folder that is
    /// on the PATH (the login shell's unless given) and writable, or else in the last folder,
    /// /usr/local/bin, with an administrator password when needed.
    @discardableResult
    func install(searchPath: [String]? = nil) async throws -> URL {
        var path = searchPath
        if path == nil { path = await loginShellPath() }
        let folder = installFolder(searchPath: path ?? [])
        let link = link(in: folder)
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            guard Self.isClaudePool(target) else { throw CommandLineInstallError.occupied(link.path) }
        } else if FileManager.default.fileExists(atPath: link.path) {
            throw CommandLineInstallError.occupied(link.path)
        }
        if FileManager.default.isWritableFile(atPath: folder.path) {
            do {
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: executable.path)
            } catch {
                throw CommandLineInstallError.failed(error.localizedDescription)
            }
        } else {
            try await asAdministrator("/bin/mkdir -p \"$1\" && /bin/ln -sfn \"$2\" \"$3\"", folder.path, executable.path, link.path)
        }
        return link
    }

    /// Removes every Claude Pool link in the known folders; other files are left alone.
    func uninstall() async throws {
        for folder in folders {
            let link = link(in: folder)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), Self.isClaudePool(target) else { continue }
            if FileManager.default.isWritableFile(atPath: folder.path) {
                do { try FileManager.default.removeItem(at: link) } catch { throw CommandLineInstallError.failed(error.localizedDescription) }
            } else {
                try await asAdministrator("/bin/rm -f \"$1\"", link.path)
            }
        }
    }

    // MARK: - Helpers

    private func installFolder(searchPath: [String]) -> URL {
        let fm = FileManager.default
        if let existing = folders.first(where: { folder in
            (try? fm.destinationOfSymbolicLink(atPath: link(in: folder).path)).map(Self.isClaudePool) == true
        }) {
            return existing
        }
        let writable = folders.dropLast().first { folder in
            searchPath.contains(folder.path) && fm.isWritableFile(atPath: folder.path)
        }
        return writable ?? folders.last ?? Self.systemFolder
    }

    /// The PATH an interactive login shell sets up, which is what a new terminal uses.
    func loginShellPath() async -> [String]? {
        let shell = URL(fileURLWithPath: loginShell).lastPathComponent == "bash" ? "/bin/bash" : "/bin/zsh"
        guard let result = try? await runner.run(
            URL(fileURLWithPath: shell),
            arguments: ["-ilc", #"printf 'CP_PATH:%s\n' "$PATH""#],
            environment: ChildEnvironment.loginShell(home: home),
            timeout: 5
        ), !result.timedOut else { return nil }
        // .zshrc output may come first; the marked line is the answer.
        guard let line = result.stdoutText.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("CP_PATH:") }) else { return nil }
        return line.dropFirst("CP_PATH:".count).split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
    }

    /// Runs a fixed sh command as root after macOS asks for an administrator password. Paths are
    /// passed as arguments ($1, $2, …), never put into the command text.
    private func asAdministrator(_ command: String, _ arguments: String...) async throws {
        let script = """
        on run argv
            set cmd to "/bin/sh -c " & quoted form of (item 1 of argv) & " sh"
            repeat with value in rest of argv
                set cmd to cmd & " " & quoted form of (contents of value)
            end repeat
            do shell script cmd with administrator privileges
        end run
        """
        let result = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script, command] + arguments,
            environment: ChildEnvironment.loginShell(home: home),
            timeout: 300
        )
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-128") { throw CommandLineInstallError.cancelled }
        if result.timedOut { throw CommandLineInstallError.failed("the password prompt timed out.") }
        guard result.exitCode == 0 else { throw CommandLineInstallError.failed(message.isEmpty ? "osascript exited with code \(result.exitCode)." : message) }
    }

    /// A link target that is the app's executable: in any copy of ClaudePool.app, or a build.
    static func isClaudePool(_ target: String) -> Bool {
        URL(fileURLWithPath: target).lastPathComponent == "ClaudePool"
    }

    private static func canonical(_ path: String, relativeTo folder: URL) -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
