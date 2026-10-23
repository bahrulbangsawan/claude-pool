import Foundation
import PoolShared

// claude-pool-collector --profile <UUID> [--record-only]
//
// Invoked by Claude Code as a status line command. Reads the status line JSON from stdin,
// keeps only rate-limit fields, updates ~/.claude-pool/usage/<UUID>.json, then prints the managed
// status line (if enabled for this profile), the user's original status line (chained), or a short
// summary. Display fields used for a managed status line are never written to disk.
// --record-only (Claude Pool's "Check usage now") stops after the update and prints nothing.
//
// Rules: never write to stdout on error, diagnostics go to stderr, always exit 0, no network.

let maxInputBytes = 1 << 20

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("claude-pool-collector: \(message)\n".utf8))
    exit(0)
}

func parseProfileID(_ arguments: [String]) -> UUID? {
    guard let index = arguments.firstIndex(of: "--profile"), index + 1 < arguments.count else { return nil }
    return UUID(uuidString: arguments[index + 1])
}

/// Reads stdin to EOF; returns nil when it exceeds the cap.
func readInput(limit: Int) -> Data? {
    var data = Data()
    let handle = FileHandle.standardInput
    while true {
        guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
        data.append(chunk)
        if data.count > limit { return nil }
    }
    return data
}

func summary(_ input: RateLimitInput) -> String? {
    var parts: [String] = []
    if let window = input.fiveHour { parts.append("5h \(Int(window.usedPercentage.rounded()))%") }
    if let window = input.sevenDay { parts.append("7d \(Int(window.usedPercentage.rounded()))%") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

func readChainCommand(_ url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
}

func firstLine(of data: Data) -> String? {
    String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
}

signal(SIGPIPE, SIG_IGN)

guard let requestedID = parseProfileID(CommandLine.arguments) else {
    fail("usage: claude-pool-collector --profile <UUID>")
}
guard let inputData = readInput(limit: maxInputBytes) else {
    fail("input larger than 1 MiB ignored")
}
let input: RateLimitInput
do {
    input = try RateLimitInput.decode(inputData)
} catch {
    fail("input is not a JSON object")
}

let paths = PoolPaths.resolve()
let recordOnly = CommandLine.arguments.contains("--record-only")
// A status line run can be another profile's session using the Default profile's command (see
// ProfileDirectories); its CLAUDE_CONFIG_DIR decides. --record-only names the profile itself.
let profileID = recordOnly ? requestedID : ProfileDirectories.load(paths.profileDirectories)?
    .profile(forConfigDir: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]) ?? requestedID
do {
    try SnapshotWriter(paths: paths, profileID: profileID, now: Date()).apply(input)
} catch {
    // Still render the status line below; only the snapshot update failed.
    FileHandle.standardError.write(Data("claude-pool-collector: \(error.localizedDescription)\n".utf8))
    // Claude Pool, not Claude Code, runs --record-only, so it gets the failure as an exit code.
    if recordOnly { exit(1) }
}
if recordOnly { exit(0) }

let chainURL = paths.chainCommand(for: profileID)
let chainCommand: String? = readChainCommand(chainURL)

// Managed status line: render Claude Pool's layout (falls back below if anything is missing).
if let state = StatuslineFiles.loadProfile(paths, id: profileID), state.managed,
   let config = StatuslineFiles.loadConfig(paths),
   let payload = StatuslinePayload.decode(inputData) {
    let now = Date()
    var values = payload.values(rateLimits: input, profile: state, now: now)
    if config.usesGit, let directory = values.cwd {
        let git = GitProbe.probe(directory: directory)
        values.gitBranch = git.branch
        values.gitStatus = git.status
    }
    if config.usesOriginal, let chainCommand, let output = ChainRunner.run(command: chainCommand, input: inputData) {
        values.originalStatusLine = firstLine(of: output)
    }
    let text = StatuslineRenderer(config: config).ansi(values: values, width: TerminalWidth.current())
    if !text.isEmpty { FileHandle.standardOutput.write(Data(text.utf8)) }
    exit(0)
}

if let command = chainCommand {
    if let output = ChainRunner.run(command: command, input: inputData) {
        FileHandle.standardOutput.write(output)
    }
} else {
    let mode = (try? String(contentsOf: paths.collectorOutputSetting, encoding: .utf8))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .flatMap(CollectorOutputMode.init(rawValue:)) ?? .summary
    if mode == .summary, let text = summary(input) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
exit(0)
