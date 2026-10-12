import Foundation
import PoolShared

/// Fields of Claude Code's status line JSON used only to RENDER a managed status line.
///
/// Compliance: these values are held in memory for one run and printed to stdout for Claude Code.
/// They are never written to disk; `SnapshotWriter` only ever receives `RateLimitInput`.
struct StatuslinePayload: Decodable {
    struct Model: Decodable { let display_name: String?; let id: String? }
    struct Workspace: Decodable { let current_dir: String? }
    struct Cost: Decodable {
        let total_cost_usd: Double?
        let total_duration_ms: Double?
        let total_lines_added: Int?
        let total_lines_removed: Int?
    }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
    struct ContextWindow: Decodable {
        let total_input_tokens: Int?
        let context_window_size: Int?
        let used_percentage: Double?
        let current_usage: Usage?
    }
    struct Named: Decodable { let name: String? }
    struct Mode: Decodable { let mode: String? }
    struct Effort: Decodable { let level: String? }

    let cwd: String?
    let session_name: String?
    let model: Model?
    let workspace: Workspace?
    let version: String?
    let output_style: Named?
    let cost: Cost?
    let context_window: ContextWindow?
    let vim: Mode?
    let effort: Effort?

    static func decode(_ data: Data) -> StatuslinePayload? {
        try? JSONDecoder().decode(StatuslinePayload.self, from: data)
    }

    func values(rateLimits: RateLimitInput, profile: StatuslineProfileState, now: Date) -> StatuslineValues {
        var v = StatuslineValues(now: now)
        v.model = model?.display_name ?? model?.id
        v.cwd = workspace?.current_dir ?? cwd
        v.sessionName = session_name
        v.version = version
        v.outputStyle = output_style?.name
        v.costUSD = cost?.total_cost_usd
        v.durationMs = cost?.total_duration_ms
        v.linesAdded = cost?.total_lines_added
        v.linesRemoved = cost?.total_lines_removed
        v.contextPercent = context_window?.used_percentage
        v.contextTokens = context_window?.total_input_tokens
        v.contextSize = context_window?.context_window_size
        if let usage = context_window?.current_usage {
            v.lastInput = usage.input_tokens
            v.lastOutput = usage.output_tokens
            v.lastCacheRead = usage.cache_read_input_tokens
            v.lastCacheWrite = usage.cache_creation_input_tokens
        }
        v.vimMode = vim?.mode
        v.effort = effort?.level
        v.fiveHour = rateLimits.fiveHour.map { UsageWindow(usedPercentage: $0.usedPercentage, resetsAt: Date(timeIntervalSince1970: $0.resetsAt)) }
        v.sevenDay = rateLimits.sevenDay.map { UsageWindow(usedPercentage: $0.usedPercentage, resetsAt: Date(timeIntervalSince1970: $0.resetsAt)) }
        v.account = profile.account
        v.plan = profile.plan
        v.profile = profile.profileName
        return v
    }
}

/// Branch and working-tree counts from `git`, bounded by a timeout. Local only.
enum GitProbe {
    static let timeout: TimeInterval = 1

    static func probe(directory: String) -> (branch: String?, status: StatuslineValues.GitStatus?) {
        guard FileManager.default.fileExists(atPath: directory) else { return (nil, nil) }
        guard let output = run(["-C", directory, "--no-optional-locks", "status", "--porcelain=v2", "--branch"]) else { return (nil, nil) }
        var branch: String?
        var status = StatuslineValues.GitStatus()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                branch = head == "(detached)" ? "detached" : head
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let xy = line.dropFirst(2).prefix(2)
                if xy.first != "." { status.staged += 1 }
                if xy.last != "." { status.modified += 1 }
            } else if line.hasPrefix("u ") {
                status.conflicts += 1
            } else if line.hasPrefix("? ") {
                status.untracked += 1
            }
        }
        return (branch, status)
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let buffer = GitOutput()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            buffer.set((try? out.fileHandleForReading.readToEnd()) ?? Data())
            read.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        _ = read.wait(timeout: .now() + 0.2)
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: buffer.get(), as: UTF8.self)
    }
}

private final class GitOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}

/// Width of the terminal Claude Code runs in, via the controlling terminal; nil when unknown.
enum TerminalWidth {
    static func current() -> Int? {
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init), columns > 20 { return columns }
        let fd = open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 20 else { return nil }
        return Int(size.ws_col)
    }
}
