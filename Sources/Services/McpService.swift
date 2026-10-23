import Foundation

/// Runs Claude Code's own `claude mcp` commands for one profile: list, get, add, remove and
/// logout. Sign-in itself is `McpLoginFlow`. Claude Code keeps every MCP sign-in in its Keychain
/// entry for the profile's config directory; Claude Pool never reads it.
struct McpService: Sendable {
    /// `claude mcp list` health-checks every server (up to 30 s each), so it gets its own runner
    /// instead of holding the shared one's two slots that sign-in checks use.
    static let runner = ProcessRunner(maxConcurrent: 3)
    static let listTimeout: TimeInterval = 120
    static let commandTimeout: TimeInterval = 60

    let home: URL
    let loginShell: String
    var runner: ProcessRunner = McpService.runner

    func list(_ profile: Profile, binary: ClaudeBinary) async throws -> [McpServer] {
        let result = try await run(["mcp", "list"], profile: profile, binary: binary, timeout: Self.listTimeout)
        if result.timedOut { throw McpServiceError.timedOut }
        let text = result.stdoutText
        guard result.exitCode == 0 else { throw McpServiceError.failed(Self.message(in: result) ?? "claude mcp list exited with code \(result.exitCode).") }
        return McpOutputParser.parseList(text)
    }

    /// One server's current state; nil when the profile has no server with that name.
    func get(_ name: String, profile: Profile, binary: ClaudeBinary) async throws -> McpServer? {
        let result = try await run(["mcp", "get", name], profile: profile, binary: binary, timeout: Self.commandTimeout)
        if result.timedOut { throw McpServiceError.timedOut }
        if let server = McpOutputParser.parseGet(result.stdoutText, name: name) { return server }
        if Self.isMissing(result) { return nil }
        throw McpServiceError.failed(Self.message(in: result) ?? "claude mcp get exited with code \(result.exitCode).")
    }

    enum AddOutcome: Equatable, Sendable { case added, alreadyPresent }

    /// `claude mcp add --transport <t> --scope user <name> <url>`. A server of that name that is
    /// already there (for example copied by Shared Extensions a moment earlier) is not an error.
    func add(name: String, url: String, transport: McpTransport, profile: Profile, binary: ClaudeBinary) async throws -> AddOutcome {
        let result = try await run(["mcp", "add", "--transport", transport.rawValue, "--scope", "user", name, url],
                                   profile: profile, binary: binary, timeout: Self.commandTimeout)
        if result.timedOut { throw McpServiceError.timedOut }
        if result.exitCode == 0 { return .added }
        if Self.combined(result).lowercased().contains("already exists") { return .alreadyPresent }
        throw McpServiceError.failed(Self.message(in: result) ?? "claude mcp add exited with code \(result.exitCode).")
    }

    /// `claude mcp remove <name>`; a server that is already gone is not an error.
    func remove(_ name: String, profile: Profile, binary: ClaudeBinary) async throws {
        let result = try await run(["mcp", "remove", name], profile: profile, binary: binary, timeout: Self.commandTimeout)
        if result.timedOut { throw McpServiceError.timedOut }
        guard result.exitCode != 0, !Self.isMissing(result) else { return }
        throw McpServiceError.failed(Self.message(in: result) ?? "claude mcp remove exited with code \(result.exitCode).")
    }

    /// `claude mcp logout <name>`: Claude Code clears the stored sign-in for this profile.
    func signOut(_ name: String, profile: Profile, binary: ClaudeBinary) async throws {
        let result = try await run(["mcp", "logout", name], profile: profile, binary: binary, timeout: Self.commandTimeout)
        if result.timedOut { throw McpServiceError.timedOut }
        guard result.exitCode != 0 else { return }
        throw McpServiceError.failed(Self.message(in: result) ?? "claude mcp logout exited with code \(result.exitCode).")
    }

    /// Environment for `claude mcp` commands. Health checks start stdio servers (npx, uvx …), so
    /// PATH comes from the login shell, as in a Terminal session.
    func environment(for profile: Profile, binary: ClaudeBinary) async -> [String: String] {
        var env = ChildEnvironment.claude(home: home, binary: binary, configDir: profile.configDirEnvironmentValue)
        if let path = await LoginShellPath.shared.value(shell: loginShell, home: home) {
            env["PATH"] = "\(path):\(binary.directory)"
        }
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    private func run(_ arguments: [String], profile: Profile, binary: ClaudeBinary, timeout: TimeInterval) async throws -> ProcessResult {
        try await runner.run(binary.url, arguments: arguments, environment: await environment(for: profile, binary: binary),
                             currentDirectory: home, timeout: timeout)
    }

    // MARK: Output

    private static func combined(_ result: ProcessResult) -> String {
        result.stdoutText + "\n" + String(decoding: result.stderr, as: UTF8.self)
    }

    static func isMissing(_ result: ProcessResult) -> Bool {
        let text = combined(result)
        return text.contains("No MCP server named") || text.contains("No MCP server found")
    }

    /// The last meaningful line Claude Code printed, URLs shortened (for error messages).
    static func message(in result: ProcessResult) -> String? {
        let lines = combined(result).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[mcp-sdk]") && !$0.hasPrefix("Checking MCP server health") }
        return lines.last.map { McpOutputParser.cleanReason($0) }
    }
}

enum McpServiceError: Error, LocalizedError, Equatable {
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        case .timedOut: "Claude Code didn't answer in time. Try again."
        }
    }
}

/// The PATH an interactive login shell sets up, read once. GUI apps start with a minimal PATH,
/// which would make stdio servers that run through npx or uvx look broken.
actor LoginShellPath {
    static let shared = LoginShellPath()
    private static let marker = "__CLAUDE_POOL_PATH__="
    /// The one probe; callers that arrive while it runs wait for the same answer.
    private var probe: Task<String?, Never>?

    func value(shell: String, home: URL, runner: ProcessRunner = .shared) async -> String? {
        if let probe { return await probe.value }
        let task = Task { await Self.read(shell: shell, home: home, runner: runner) }
        probe = task
        return await task.value
    }

    private static func read(shell: String, home: URL, runner: ProcessRunner) async -> String? {
        // Only POSIX-style shells understand the probe; others fall back to zsh, macOS's default.
        let name = URL(fileURLWithPath: shell).lastPathComponent
        let probe = ["zsh", "bash", "sh"].contains(name) ? shell : "/bin/zsh"
        guard let result = try? await runner.run(
            URL(fileURLWithPath: probe),
            arguments: ["-ilc", "printf '%s%s\\n' '\(marker)' \"$PATH\""],
            environment: ChildEnvironment.loginShell(home: home),
            timeout: 8
        ), !result.timedOut else { return nil }
        // Shell start-up files may print first; take the marked line.
        let line = result.stdoutText.split(whereSeparator: \.isNewline).last { $0.hasPrefix(marker) }
        guard let path = line.map({ String($0.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces) }), path.contains("/") else { return nil }
        return path
    }
}
