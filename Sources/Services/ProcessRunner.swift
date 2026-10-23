import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

enum ProcessRunnerError: Error, LocalizedError {
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(path, reason): "Could not run \(path): \(reason)"
        }
    }
}

/// Runs subprocesses with an argument array and an explicit environment (never a shell string
/// built from user data). Async, with a timeout that kills the process, and at most two at once.
actor ProcessRunner {
    static let shared = ProcessRunner(maxConcurrent: 2)

    /// Names that are never passed to a child, even if a caller adds them by mistake.
    static let scrubbedVariableNames: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", // static-check:allow
    ]

    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        await acquire()
        defer { release() }
        let env = environment.filter { !Self.scrubbedVariableNames.contains($0.key) && !$0.key.hasPrefix("ANTHROPIC_") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runBlocking(
                        executable, arguments: arguments, environment: env,
                        currentDirectory: currentDirectory, input: input, timeout: timeout
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }

    private static func runBlocking(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        input: Data?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(executable.path, error.localizedDescription)
        }
        if let inPipe, let input {
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }

        let out = DataBox()
        let err = DataBox()
        let readers = DispatchGroup()
        for (pipe, box) in [(outPipe, out), (errPipe, err)] {
            readers.enter()
            let handle = pipe.fileHandleForReading
            DispatchQueue.global().async {
                box.set((try? handle.readToEnd()) ?? Data())
                readers.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // Interactive shells can leave background children holding the pipes; cap the wait.
        _ = readers.wait(timeout: .now() + 1)
        return ProcessResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: out.get(),
            stderr: err.get(),
            timedOut: timedOut
        )
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}

/// Environment helpers shared by services that start child processes.
enum ChildEnvironment {
    static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Minimal environment for an interactive login shell probe.
    static func loginShell(home: URL, user: String = NSUserName()) -> [String: String] {
        [
            "HOME": home.path,
            "USER": user,
            "LOGNAME": user,
            "PATH": basePath,
            "TERM": "dumb",
            "LANG": "en_US.UTF-8",
        ]
    }

    /// Environment for the herdr CLI, which finds its server socket under HOME.
    static func herdr(home: URL, user: String = NSUserName()) -> [String: String] {
        [
            "HOME": home.path,
            "USER": user,
            "LOGNAME": user,
            "PATH": basePath,
            "LANG": "en_US.UTF-8",
        ]
    }

    /// Environment for running the `claude` binary. USER and LOGNAME are required: without
    /// them Claude Code cannot find its Keychain sign-in and reports "signed out".
    /// CLAUDE_CONFIG_DIR is added only for non-default profiles.
    static func claude(home: URL, binary: ClaudeBinary, configDir: String?, user: String = NSUserName()) -> [String: String] {
        var env = [
            "HOME": home.path,
            "USER": user,
            "LOGNAME": user,
            "PATH": "\(basePath):\(binary.directory)",
        ]
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir }
        return env
    }
}
