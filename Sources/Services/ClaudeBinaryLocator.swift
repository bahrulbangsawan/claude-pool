import Foundation

struct ClaudeBinary: Hashable, Sendable {
    enum Source: String, Sendable {
        case userOverride = "Settings override"
        case loginShell = "login shell PATH"
        case fallback = "known install location"
    }

    var path: String
    var source: Source
    var version: String?

    var url: URL { URL(fileURLWithPath: path) }
    var directory: String { url.deletingLastPathComponent().path }
}

/// Finds the `claude` executable. GUI apps do not inherit the shell PATH, so it asks a login shell.
struct ClaudeBinaryLocator: Sendable {
    let home: URL
    var runner: ProcessRunner = .shared

    var fallbackPaths: [String] {
        [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path,
        ]
    }

    func locate(override: String?) async -> ClaudeBinary? {
        let fm = FileManager.default
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            let expanded = override.hasPrefix("~/") ? home.appendingPathComponent(String(override.dropFirst(2))).path : override
            if fm.isExecutableFile(atPath: expanded) {
                return await withVersion(ClaudeBinary(path: expanded, source: .userOverride))
            }
        }
        if let path = await fromLoginShell() {
            return await withVersion(ClaudeBinary(path: path, source: .loginShell))
        }
        if let path = fallbackPaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return await withVersion(ClaudeBinary(path: path, source: .fallback))
        }
        return nil
    }

    private func fromLoginShell() async -> String? {
        guard let result = try? await runner.run(
            URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-ilc", "whence -p claude"],
            environment: ChildEnvironment.loginShell(home: home),
            timeout: 5
        ), !result.timedOut else { return nil }
        // .zshrc output may precede the answer; take the last line that is an executable.
        let lines = result.stdoutText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.reversed().first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func withVersion(_ binary: ClaudeBinary) async -> ClaudeBinary {
        var binary = binary
        binary.version = await version(of: binary)
        return binary
    }

    func version(of binary: ClaudeBinary) async -> String? {
        guard let result = try? await runner.run(
            binary.url,
            arguments: ["--version"],
            environment: ChildEnvironment.claude(home: home, binary: binary, configDir: nil),
            timeout: 10
        ), result.exitCode == 0 else { return nil }
        let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }
}
