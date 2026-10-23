import AppKit
import Darwin
import Foundation

enum HerdrError: Error, LocalizedError, Equatable {
    case notInstalled
    case notRunning
    case startTimedOut
    case failed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "herdr isn't installed. Install it in Settings › Terminal, or set Open in back to Terminal."
        case .notRunning: "herdr isn't running. Start herdr in a terminal, then try again."
        case .startTimedOut: "herdr is starting in Terminal. Finish its first-run setup there, then click Open Terminal again."
        case let .failed(message): "herdr couldn't open a tab: \(message)"
        case let .installFailed(message): "Couldn't install herdr: \(message)"
        }
    }
}

/// Opens a launcher script in a new tab of the running herdr session (herdr.dev) through the
/// herdr CLI. The tab's shell runs the same script as Terminal, so the profile is set the same way.
struct HerdrClient: Sendable {
    let home: URL
    var runner: ProcessRunner = .shared
    /// Checked in order; GUI apps do not inherit the shell PATH.
    var candidatePaths: [String]

    init(home: URL) {
        self.home = home
        candidatePaths = [
            home.appendingPathComponent(".local/bin/herdr").path,
            home.appendingPathComponent(".cargo/bin/herdr").path,
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
        ]
    }

    var binary: URL? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Creates a focused tab named `label` in herdr's current workspace, then types the quoted
    /// script path into the tab's shell.
    func openTab(running script: URL, label: String, workingDirectory: String) async throws {
        guard let binary else { throw HerdrError.notInstalled }
        var arguments = ["tab", "create", "--label", label, "--focus"]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
            arguments += ["--cwd", workingDirectory]
        }
        let created = try await run(binary, arguments)
        guard let pane = Self.reply(created)?.result?.rootPane?.paneId else {
            throw HerdrError.failed("herdr tab create did not return a pane.")
        }
        _ = try await run(binary, ["pane", "run", pane, ShellQuote.quote(script.path)])
    }

    /// Whether herdr's server is up, from `herdr status --json` (which exits 0 either way).
    func serverIsRunning() async -> Bool {
        struct Status: Decodable {
            struct Server: Decodable { var running: Bool? }
            var server: Server?
        }
        guard let binary,
              let result = try? await runner.run(binary, arguments: ["status", "--json"], environment: ChildEnvironment.herdr(home: home), timeout: 5),
              !result.timedOut, result.exitCode == 0 else { return false }
        return (try? JSONDecoder().decode(Status.self, from: result.stdout))?.server?.running == true
    }

    /// Polls until herdr's server is up; false after `timeout`.
    func waitForServer(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await serverIsRunning() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        } while Date() < deadline
        return false
    }

    // MARK: - Install

    static let installerURL = "https://herdr.dev/install.sh"

    /// Runs herdr's official installer, which checks the download against the release's SHA-256 and
    /// puts the binary in ~/.local/bin without sudo. Returns the installed binary.
    func install(from installer: String = Self.installerURL) async throws -> URL {
        // Saved to a file first, so a cut-off download never runs as a partial script.
        let script = #"set -e; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT; curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$1" -o "$dir/install.sh"; sh "$dir/install.sh""#
        let result = try await runner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "sh", installer],
            environment: ChildEnvironment.herdr(home: home), timeout: 180
        )
        if result.timedOut { throw HerdrError.installFailed("the installer timed out after 3 minutes.") }
        guard result.exitCode == 0 else {
            throw HerdrError.installFailed(Self.lastLine(result.stderr) ?? Self.lastLine(result.stdout) ?? "the installer exited with code \(result.exitCode).")
        }
        guard let binary else { throw HerdrError.installFailed("the installer finished, but herdr isn't in ~/.local/bin.") }
        return binary
    }

    /// The last non-empty output line without colour codes or the installer's ✗/> markers.
    static func lastLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "✗>!").union(.whitespaces)) }
            .last { !$0.isEmpty }
    }

    private func run(_ binary: URL, _ arguments: [String]) async throws -> Data {
        let command = "herdr " + arguments.prefix(2).joined(separator: " ")
        let result = try await runner.run(binary, arguments: arguments, environment: ChildEnvironment.herdr(home: home), timeout: 10)
        if result.timedOut { throw HerdrError.failed("\(command) timed out after 10 seconds.") }
        guard result.exitCode == 0 else {
            // Server errors are JSON (on stderr, or stdout in some versions); usage errors are plain text.
            if let failure = Self.reply(result.stderr)?.error ?? Self.reply(result.stdout)?.error {
                if failure.code == "server_not_running" { throw HerdrError.notRunning }
                throw HerdrError.failed(failure.message ?? failure.code ?? "\(command) failed.")
            }
            let text = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrError.failed(text.isEmpty ? "\(command) exited with code \(result.exitCode)." : text)
        }
        return result.stdout
    }

    // MARK: - Replies

    struct Reply: Decodable {
        struct Failure: Decodable {
            var code: String?
            var message: String?
        }

        struct Result: Decodable {
            struct Pane: Decodable { var paneId: String }
            var rootPane: Pane?
        }

        var result: Result?
        var error: Failure?
    }

    static func reply(_ data: Data) -> Reply? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Reply.self, from: data)
    }

    // MARK: - Host window

    /// The app showing herdr: the nearest regular-app ancestor of a running herdr client. The
    /// herdr server runs detached under launchd, so it never matches.
    @MainActor
    static func hostApplication() -> NSRunningApplication? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        for pid in pids.prefix(Int(count)) {
            guard let process = process(pid), process.name == "herdr" else { continue }
            var parent = process.parent
            // A process tree is shallow; the cap only guards against a malformed chain.
            for _ in 0..<32 where parent > 1 {
                if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                    return app
                }
                guard let next = Self.process(parent) else { break }
                parent = next.parent
            }
        }
        return nil
    }

    /// Name and parent of any process (kern.proc.pid). proc_pidinfo is not used because it is
    /// refused for root-owned processes such as the `login` between Terminal and its shell.
    private static func process(_ pid: pid_t) -> (name: String, parent: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (name, info.kp_eproc.e_ppid)
    }
}
