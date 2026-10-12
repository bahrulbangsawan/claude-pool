import Foundation
import Observation

/// Signs a profile in without Terminal by running Claude Code's own `claude auth login --claudeai`
/// for that profile's directory.
///
/// How it works (verified against Claude Code 2.1.296):
/// - Without a TTY, `claude auth login` prints "If the browser didn't open, visit: <url>" (a URL whose
///   page shows a code to paste) and then waits on stdin for "Paste code here if prompted >".
/// - It also starts its own localhost callback and asks `$BROWSER` (or `open`) to open a second URL.
///   Claude Pool points `BROWSER` at a tiny script that only records that URL, so the browser is
///   opened when *you* choose, and completing sign-in there finishes automatically.
/// - Claude Code exchanges the code and stores the credentials in the macOS Keychain entry for
///   that config directory. Claude Pool never sees, stores or logs a token; the pasted code goes
///   straight to the process's stdin and is not kept.
@MainActor
@Observable
final class LoginFlow: Identifiable {
    enum Phase: Equatable {
        case starting
        case waitingForAuthorization
        case submittingCode
        case verifying
        case succeeded(AuthStatus)
        case failed(String)
        case expired
        case cancelled

        var isFinished: Bool {
            switch self {
            case .succeeded, .failed, .expired, .cancelled: true
            default: false
            }
        }
    }

    static let lifetime: TimeInterval = 10 * 60

    let id = UUID()
    let profile: Profile
    private(set) var phase: Phase = .starting
    /// Works in any browser on any device: its page shows a code to paste back here.
    private(set) var manualURL: URL?
    /// Completes on its own through Claude Code's localhost callback (this Mac only).
    private(set) var callbackURL: URL?
    private(set) var startedAt = Date()
    private(set) var expiresAt = Date().addingTimeInterval(LoginFlow.lifetime)
    /// The previous account of this profile, to point out an account change after success.
    let previousIdentity: String?

    @ObservationIgnored private let binary: ClaudeBinary
    @ObservationIgnored private let paths: Paths
    @ObservationIgnored private let verify: @MainActor (Profile) async -> AuthStatus?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: FileHandle?
    @ObservationIgnored private var output = OutputAccumulator()
    @ObservationIgnored private var captureDirectory: URL?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var codeSubmitted = false

    init(profile: Profile, binary: ClaudeBinary, paths: Paths, previousIdentity: String?,
         verify: @escaping @MainActor (Profile) async -> AuthStatus?) {
        self.profile = profile
        self.binary = binary
        self.paths = paths
        self.previousIdentity = previousIdentity
        self.verify = verify
    }

    // MARK: Lifecycle

    func start(emailHint: String? = nil) {
        guard phase == .starting || phase.isFinished else { return }
        teardown()
        phase = .starting
        manualURL = nil
        callbackURL = nil
        codeSubmitted = false
        output = OutputAccumulator()
        startedAt = Date()
        expiresAt = startedAt.addingTimeInterval(Self.lifetime)

        do {
            let capture = try makeCaptureDirectory()
            captureDirectory = capture
            let process = Process()
            process.executableURL = binary.url
            var arguments = ["auth", "login", "--claudeai"]
            if let emailHint = emailHint?.trimmingCharacters(in: .whitespacesAndNewlines), !emailHint.isEmpty, emailHint.contains("@") {
                arguments += ["--email", emailHint]
            }
            process.arguments = arguments
            var environment = ChildEnvironment.claude(home: paths.userHome, binary: binary, configDir: profile.configDirEnvironmentValue)
            environment["BROWSER"] = capture.appendingPathComponent("record-url").path
            environment[Self.captureVariable] = capture.appendingPathComponent("url").path
            process.environment = environment
            process.currentDirectoryURL = paths.userHome
            let input = Pipe(), out = Pipe(), err = Pipe()
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            let accumulator = output
            for handle in [out.fileHandleForReading, err.fileHandleForReading] {
                handle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil } else { accumulator.append(chunk) }
                }
            }
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor in await self?.processExited(status: status) }
            }
            try process.run()
            self.process = process
            stdin = input.fileHandleForWriting
        } catch {
            phase = .failed("Couldn't start Claude Code's sign-in: \(error.localizedDescription)")
            teardown()
            return
        }

        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.pollOutput()
            }
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lifetime))
            guard let self, !Task.isCancelled else { return }
            if !self.phase.isFinished, self.phase != .verifying {
                self.phase = .expired
                self.terminateProcess()
            }
        }
    }

    /// Sends the code shown on the authorization page. Expected shape: `<code>#<state>`.
    func submit(code raw: String) {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .waitingForAuthorization else { return }
        guard Self.isPlausibleCode(code) else {
            phase = .failed("That doesn't look like a complete code. Copy the whole code from the authorization page (it contains a #), then try again.")
            terminateProcess()
            return
        }
        guard let stdin else { return }
        codeSubmitted = true
        phase = .submittingCode
        do {
            try stdin.write(contentsOf: Data((code + "\n").utf8))
        } catch {
            phase = .failed("Couldn't pass the code to Claude Code: \(error.localizedDescription)")
            terminateProcess()
        }
    }

    func cancel() {
        guard !phase.isFinished else { return }
        phase = .cancelled
        terminateProcess()
    }

    // MARK: Internals

    static let captureVariable = "CLAUDE_POOL_LOGIN_URL_FILE"

    static func isPlausibleCode(_ code: String) -> Bool {
        let parts = code.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }), code.count <= 2_048 else { return false }
        return code.allSatisfy { !$0.isWhitespace && !$0.isNewline }
    }

    /// First `https://` URL after "visit:" in Claude Code's output.
    static func manualURL(in text: String) -> URL? {
        guard let range = text.range(of: "visit:") else { return nil }
        let rest = text[range.upperBound...]
        guard let match = rest.firstMatch(of: /https:\/\/[^\s]+/) else { return nil }
        let candidate = String(match.0)
        guard let url = URL(string: candidate), url.scheme == "https" else { return nil }
        return url
    }

    /// The last meaningful line of output, without URLs (for error messages).
    static func failureReason(in text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: #"https?://\S+"#, with: "<link>", options: .regularExpression) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Paste code here") && !$0.hasPrefix("Opening browser") && !$0.contains("didn't open") }
        return lines.last.map { String($0.prefix(300)) }
    }

    private func pollOutput() {
        if manualURL == nil, let url = Self.manualURL(in: output.text) {
            manualURL = url
        }
        if callbackURL == nil, let capture = captureDirectory,
           let text = try? String(contentsOf: capture.appendingPathComponent("url"), encoding: .utf8),
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" {
            callbackURL = url
        }
        if phase == .starting, manualURL != nil || callbackURL != nil {
            phase = .waitingForAuthorization
        }
    }

    private func processExited(status: Int32) async {
        // Let the pipe readers deliver the last lines before inspecting the output.
        try? await Task.sleep(for: .milliseconds(150))
        pollOutput()
        let text = output.text
        process = nil
        stdin = nil
        poller?.cancel()
        guard !phase.isFinished else { teardown(); return }
        if status == 0 {
            phase = .verifying
            teardown()
            if let verified = await verify(profile), verified.signedIn {
                phase = .succeeded(verified)
            } else {
                phase = .failed("Claude Code reported success, but this profile still shows as signed out. Try again, or use Sign In with Terminal.")
            }
            return
        }
        teardown()
        let reason = Self.failureReason(in: text)
        if text.contains("Invalid code") {
            phase = .failed("The code was rejected. It may be incomplete, already used, or from an older link. Start again for a fresh link.")
        } else if codeSubmitted {
            phase = .failed(reason.map { "Sign-in failed: \($0)" } ?? "Sign-in failed (exit code \(status)). Start again for a fresh link.")
        } else {
            phase = .failed(reason.map { "Claude Code stopped before sign-in finished: \($0)" } ?? "Claude Code stopped before sign-in finished (exit code \(status)).")
        }
    }

    private func makeCaptureDirectory() throws -> URL {
        try AtomicFile.ensureDirectory(paths.caches, permissions: 0o700)
        let directory = paths.caches.appendingPathComponent("login-\(id.uuidString)", isDirectory: true)
        try AtomicFile.ensureDirectory(directory, permissions: 0o700)
        // Records the URL Claude Code asks the browser to open. Nothing else.
        let script = """
        #!/bin/sh
        umask 077
        [ -n "$\(Self.captureVariable)" ] && printf '%s\\n' "$1" > "$\(Self.captureVariable)"
        exit 0

        """
        try AtomicFile.write(Data(script.utf8), to: directory.appendingPathComponent("record-url"), permissions: 0o700)
        return directory
    }

    private func terminateProcess() {
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        teardown()
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        poller?.cancel()
        poller = nil
        try? stdin?.close()
        stdin = nil
        if let captureDirectory { try? FileManager.default.removeItem(at: captureDirectory) }
        captureDirectory = nil
    }
}

/// Thread-safe text buffer for the sign-in process's output (capped; never logged).
private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            guard data.count < 256 * 1024 else { return }
            data.append(chunk)
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
