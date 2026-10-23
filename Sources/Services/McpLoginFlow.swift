import Darwin
import Foundation
import Observation

/// Signs one profile in to one MCP server by running Claude Code's own
/// `claude mcp login <name> --no-browser` for that profile's directory.
///
/// How it works (verified against Claude Code 2.1.309):
/// - It prints "Visit this URL to authorize:" and the provider's authorization URL, listens on
///   localhost for the provider's redirect, and shows "Or paste the redirect URL here:".
/// - Opened on this Mac, the page redirects to that localhost callback and sign-in completes on
///   its own. From another device, the browser ends on an unreachable `http://localhost…` page;
///   pasting that address finishes the same sign-in.
/// - The paste prompt only exists on a terminal, so the command runs on a pseudo-terminal.
/// - Success prints `Authenticated with "<name>"` and exits 0. A pasted address from another
///   sign-in is refused with a message and the prompt is shown again.
/// - For a claude.ai connector it prints a claude.ai link and exits 0: that sign-in finishes on
///   claude.ai.
/// Claude Code exchanges the code and stores the tokens in its Keychain entry for that config
/// directory. Claude Pool never sees, stores or logs a token; the pasted address goes straight to
/// the terminal and is not kept.
@MainActor
@Observable
final class McpLoginFlow: Identifiable {
    enum Phase: Equatable {
        case starting
        case waitingForAuthorization
        case checkingRedirect
        case verifying
        case succeeded
        /// A claude.ai connector: the link finishes the sign-in on claude.ai.
        case finishOnClaudeAI
        case failed(String)
        case expired
        case cancelled

        var isFinished: Bool {
            switch self {
            case .succeeded, .finishOnClaudeAI, .failed, .expired, .cancelled: true
            default: false
            }
        }
    }

    static let lifetime: TimeInterval = 10 * 60

    let id = UUID()
    let profile: Profile
    let serverName: String
    private(set) var phase: Phase = .starting {
        didSet { if phase.isFinished, !oldValue.isFinished { onFinish?(phase) } }
    }
    /// The provider's authorization page (or the claude.ai page for a connector).
    private(set) var authorizationURL: URL?
    /// Claude Code didn't accept the last pasted address; the sign-in keeps waiting.
    private(set) var redirectError: String?
    private(set) var expiresAt = Date().addingTimeInterval(McpLoginFlow.lifetime)
    @ObservationIgnored var onFinish: ((Phase) -> Void)?

    @ObservationIgnored private let binary: ClaudeBinary
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let verify: @MainActor (Profile, String) async -> McpServer?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var terminal: PseudoTerminal?
    @ObservationIgnored private var output = TerminalOutput()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var exited: [CheckedContinuation<Void, Never>] = []
    /// Output length when the last address was pasted; later output is Claude Code's answer.
    @ObservationIgnored private var submittedAt = 0

    init(profile: Profile, serverName: String, binary: ClaudeBinary, home: URL, environment: [String: String],
         verify: @escaping @MainActor (Profile, String) async -> McpServer?) {
        self.profile = profile
        self.serverName = serverName
        self.binary = binary
        self.home = home
        self.environment = environment
        self.verify = verify
    }

    var isConnector: Bool { serverName.hasPrefix(McpServer.connectorPrefix) }

    // MARK: Lifecycle

    func start() {
        guard phase == .starting || phase.isFinished, process == nil else { return }
        phase = .starting
        authorizationURL = nil
        redirectError = nil
        submittedAt = 0
        output = TerminalOutput()
        expiresAt = Date().addingTimeInterval(Self.lifetime)

        let terminal: PseudoTerminal
        do {
            terminal = try PseudoTerminal(output: output)
        } catch {
            phase = .failed("Couldn't open a terminal for Claude Code's sign-in: \(error.localizedDescription)")
            return
        }
        do {
            let process = Process()
            process.executableURL = binary.url
            process.arguments = ["mcp", "login", serverName, "--no-browser"]
            var env = environment
            env["TERM"] = "xterm-256color"
            process.environment = env
            process.currentDirectoryURL = home
            process.standardInput = terminal.secondary
            process.standardOutput = terminal.secondary
            process.standardError = terminal.secondary
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor in await self?.processExited(status: status) }
            }
            try process.run()
            terminal.closeSecondary()
            self.terminal = terminal
            self.process = process
        } catch {
            terminal.close()
            phase = .failed("Couldn't start Claude Code's sign-in: \(error.localizedDescription)")
            teardown()
            return
        }

        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
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

    /// Passes the address the browser ended on (`http://localhost:<port>/callback?code=…&state=…`)
    /// to Claude Code's prompt. Claude Code checks that it belongs to this sign-in.
    func submit(redirect raw: String) {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .waitingForAuthorization, let terminal else { return }
        guard Self.isPlausibleRedirect(address) else {
            redirectError = "That isn't the address the browser ended on. After approving, copy the whole address from the browser's address bar (it starts with http://localhost) and paste it here."
            return
        }
        redirectError = nil
        submittedAt = output.count
        phase = .checkingRedirect
        if !terminal.write(address + "\r") {
            phase = .failed("Couldn't pass the address to Claude Code.")
            terminateProcess()
        }
    }

    func cancel() {
        guard !phase.isFinished else { return }
        phase = .cancelled
        terminateProcess()
    }

    /// Cancels if needed and returns once the process has exited, so the next sign-in can reuse
    /// the same localhost callback port.
    func stop() async {
        cancel()
        guard process != nil else { return }
        await withCheckedContinuation { exited.append($0) }
    }

    // MARK: Parsing

    /// An http(s) address with an authorization code (or the provider's error), at most 8 KB.
    static func isPlausibleRedirect(_ text: String) -> Bool {
        guard text.count <= 8_192, !text.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false else { return false }
        let names = Set((components.queryItems ?? []).map(\.name))
        return names.contains("code") || names.contains("error")
    }

    /// The first URL after "Visit this URL to authorize:" (any URL if that line is missing).
    static func authorizationURL(in text: String) -> URL? {
        let tail = text.range(of: "Visit this URL").map { text[$0.upperBound...] } ?? text[...]
        guard let match = tail.firstMatch(of: /https?:\/\/[^\s]+/) else { return nil }
        guard let url = URL(string: String(match.0)), let host = url.host else { return nil }
        if url.scheme == "https" { return url }
        // Plain http only for a server on this Mac.
        return ["localhost", "127.0.0.1"].contains(host) ? url : nil
    }

    /// Terminal output as plain text: no escape sequences, "\n" line ends.
    static func plainText(_ raw: String) -> String {
        raw.replacing(/\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)/, with: "")
            .replacing(/\x{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
            .replacing(/\x{1B}[@-Z\\-_]/, with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Meaningful lines (no prompts, progress or SDK notices) with URLs replaced by "<link>".
    static func messages(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("[mcp-sdk]") && !line.hasPrefix("Or paste the redirect URL")
                    && !line.hasPrefix("Waiting for authorization") && !line.hasPrefix("Starting authentication")
                    && !line.hasPrefix("Visit this URL") && !line.hasPrefix("http")
            }
            .map { $0.replacing(/https?:\/\/\S+/, with: "<link>") }
            .map { String($0.prefix(300)) }
    }

    // MARK: Internals

    private func pollOutput() {
        let text = Self.plainText(output.text)
        if authorizationURL == nil, let url = Self.authorizationURL(in: text) {
            authorizationURL = url
        }
        if phase == .starting, authorizationURL != nil {
            phase = .waitingForAuthorization
        }
        if phase == .checkingRedirect {
            // Claude Code refused the address: it explains why and asks again.
            let answer = Self.plainText(output.text(from: submittedAt))
            let lines = answer.split(whereSeparator: \.isNewline).dropFirst() // the echoed address
            if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Or paste the redirect URL") }) {
                let reason = Self.messages(in: lines.joined(separator: "\n")).last
                redirectError = reason.map { "Claude Code didn't accept that address: \($0)" }
                    ?? "Claude Code didn't accept that address. Copy the whole address from this sign-in's browser page and try again."
                phase = .waitingForAuthorization
            }
        }
    }

    private func processExited(status: Int32) async {
        // Let the terminal reader deliver the last lines before inspecting the output.
        try? await Task.sleep(for: .milliseconds(150))
        pollOutput()
        let text = Self.plainText(output.text)
        process = nil
        teardown()
        for continuation in exited { continuation.resume() }
        exited = []
        guard !phase.isFinished else { return }
        if status == 0 {
            if isConnector || text.contains("Once authorized on claude.ai") {
                phase = authorizationURL == nil ? .failed("Claude Code didn't print a claude.ai link for this connector.") : .finishOnClaudeAI
                return
            }
            phase = .verifying
            let server = await verify(profile, serverName)
            switch server?.health {
            case .connected?:
                phase = .succeeded
            case .needsSignIn?:
                phase = .failed("Claude Code finished, but \(McpServer.displayName(for: serverName)) still needs a sign-in in this profile. Start again for a fresh link.")
            default:
                // Signed in, even if the server can't be reached right now.
                phase = text.contains("Authenticated with") ? .succeeded
                    : .failed(Self.messages(in: text).last.map { "Sign-in didn't finish: \($0)" } ?? "Sign-in didn't finish. Start again for a fresh link.")
            }
            return
        }
        let reason = Self.messages(in: text).last
        phase = .failed(reason.map { "Claude Code stopped before sign-in finished: \($0)" }
            ?? "Claude Code stopped before sign-in finished (exit code \(status)).")
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
        // The termination handler runs `processExited`, which closes the terminal and resumes `stop()`.
        watchdog?.cancel()
        watchdog = nil
        poller?.cancel()
        poller = nil
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        poller?.cancel()
        poller = nil
        terminal?.close()
        terminal = nil
    }
}

/// Thread-safe buffer for the sign-in terminal's output (capped; in memory only, never logged).
final class TerminalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            guard data.count < 512 * 1024 else { return }
            data.append(chunk)
        }
    }

    var count: Int { lock.withLock { data.count } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

    func text(from offset: Int) -> String {
        lock.withLock { String(decoding: data.dropFirst(min(offset, data.count)), as: UTF8.self) }
    }
}

/// A pseudo-terminal for one child process: the child gets the secondary side as stdin, stdout and
/// stderr; the primary side is read on a background queue and written to for the paste.
final class PseudoTerminal: @unchecked Sendable {
    let secondary: FileHandle
    private let primary: Int32
    private var secondaryOpen = true
    /// Guarded by `lock`, like every use of `primary` after closing: a write never reaches a
    /// descriptor number the system has already handed out again.
    private var primaryOpen = true
    private let source: DispatchSourceRead
    private let lock = NSLock()

    init(output: TerminalOutput, columns: UInt16 = 1000, rows: UInt16 = 50) throws {
        var primary: Int32 = -1, secondary: Int32 = -1
        // Wide, so long authorization URLs are never wrapped onto several lines.
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(primary, F_SETFD, FD_CLOEXEC)
        self.primary = primary
        self.secondary = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)
        source = DispatchSource.makeReadSource(fileDescriptor: primary, queue: DispatchQueue(label: "ClaudePool.mcp-login-terminal"))
        source.setEventHandler { [source] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = buffer.withUnsafeMutableBytes { read(primary, $0.baseAddress, $0.count) }
            if count > 0 {
                output.append(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // EOF, or EIO once the child and every copy of the secondary side are gone.
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { Darwin.close(primary); return }
            self.lock.withLock {
                self.primaryOpen = false
                Darwin.close(primary)
            }
        }
        source.resume()
    }

    /// The parent's copy of the secondary side, closed once the child has its own.
    func closeSecondary() {
        lock.withLock {
            guard secondaryOpen else { return }
            secondaryOpen = false
            try? secondary.close()
        }
    }

    @discardableResult
    func write(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return lock.withLock {
            guard primaryOpen else { return false }
            var written = 0
            while written < bytes.count {
                let result = bytes[written...].withUnsafeBytes { Darwin.write(primary, $0.baseAddress, $0.count) }
                if result < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                written += result
            }
            return true
        }
    }

    func close() {
        closeSecondary()
        source.cancel()
    }
}
