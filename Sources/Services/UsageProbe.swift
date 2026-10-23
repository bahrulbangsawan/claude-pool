import Foundation

/// Usage read from one Claude Code response, as whole percentages.
struct UsageReading: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        var usedPercentage: Double
        var resetsAt: Double
    }

    var fiveHour: Window?
    var sevenDay: Window?
}

enum UsageProbeError: Error, LocalizedError, Equatable {
    case notReported
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notReported: "Claude Code didn't report usage for this account. It does only for claude.ai Pro and Max sign-ins."
        case .timedOut: "Checking usage timed out after 45 seconds. Try again, or open a session with this profile."
        case let .failed(message): "Couldn't check usage: \(message)"
        }
    }
}

/// "Check usage now": has Claude Code send one tiny Haiku request as the profile and reads the
/// usage it reports back (`rate_limit_event`). Claude Code makes the network call; Claude Pool reads
/// its output. The request runs without tools, MCP servers, settings files (so no hooks or plugins)
/// or a saved session, and costs a few hundred tokens of that account's usage.
struct UsageProbe: Sendable {
    let paths: Paths
    var runner: ProcessRunner = .shared

    static let prompt = "Reply with OK."
    static let arguments = [
        "-p", prompt, "--system-prompt", prompt, "--model", "haiku",
        "--output-format", "stream-json", "--verbose", "--no-session-persistence",
        "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
    ]

    func check(_ profile: Profile, binary: ClaudeBinary) async throws -> UsageReading {
        // An empty folder, so no project CLAUDE.md or settings apply.
        let directory = paths.caches.appendingPathComponent("usage-check", isDirectory: true)
        try AtomicFile.ensureDirectory(directory, permissions: 0o700)
        let result = try await runner.run(
            binary.url, arguments: Self.arguments,
            environment: ChildEnvironment.claude(home: paths.userHome, binary: binary, configDir: profile.configDirEnvironmentValue),
            currentDirectory: directory, timeout: 45
        )
        if result.timedOut { throw UsageProbeError.timedOut }
        if let reading = Self.parse(result.stdout) { return reading }
        guard result.exitCode == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
            throw UsageProbeError.failed(message.flatMap { $0.isEmpty ? nil : $0 } ?? "claude exited with code \(result.exitCode).")
        }
        throw UsageProbeError.notReported
    }

    /// Stores the reading the way a status line report is stored: through the collector, as a new
    /// session, so it counts as the current value.
    func record(_ reading: UsageReading, for profile: Profile, collector: URL) async throws {
        let result = try await runner.run(
            collector, arguments: ["--profile", profile.id.uuidString, "--record-only"],
            environment: [PoolPaths.homeOverrideVariable: paths.pool.home.path, "HOME": paths.userHome.path, "PATH": ChildEnvironment.basePath],
            input: Self.payload(reading, sessionID: "usage-check-\(UUID().uuidString)"), timeout: 10
        )
        guard !result.timedOut, result.exitCode == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageProbeError.failed(message.isEmpty ? "the collector couldn't save the reading." : message)
        }
    }

    /// The status line JSON the collector reads: `session_id` and `rate_limits` only.
    static func payload(_ reading: UsageReading, sessionID: String) -> Data {
        var windows: [String: Any] = [:]
        if let window = reading.fiveHour { windows["five_hour"] = ["used_percentage": window.usedPercentage, "resets_at": window.resetsAt] }
        if let window = reading.sevenDay { windows["seven_day"] = ["used_percentage": window.usedPercentage, "resets_at": window.resetsAt] }
        let object: [String: Any] = ["session_id": sessionID, "rate_limits": windows]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: - Output

    /// The only part of the output decoded: `rate_limit_info.unifiedWindows` of `rate_limit_event`
    /// lines. Lines are pre-filtered on that name, so message content is never decoded.
    private struct Event: Decodable {
        struct Info: Decodable {
            struct Windows: Decodable {
                struct Window: Decodable {
                    let utilization: Double
                    let resetsAt: Double
                }

                let fiveHour: Window?
                let sevenDay: Window?
            }

            let unifiedWindows: Windows?
        }

        let type: String
        let rateLimitInfo: Info?
    }

    static func parse(_ output: Data) -> UsageReading? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let marker = Data("rate_limit_event".utf8)
        let windows = output.split(separator: UInt8(ascii: "\n"))
            .filter { $0.range(of: marker) != nil }
            .compactMap { try? decoder.decode(Event.self, from: Data($0)) }
            .filter { $0.type == "rate_limit_event" }
            .compactMap { $0.rateLimitInfo?.unifiedWindows }
            .last
        func window(_ window: Event.Info.Windows.Window?) -> UsageReading.Window? {
            window.map { .init(usedPercentage: ($0.utilization * 100).rounded(), resetsAt: $0.resetsAt) }
        }
        guard let windows, windows.fiveHour != nil || windows.sevenDay != nil else { return nil }
        return UsageReading(fiveHour: window(windows.fiveHour), sevenDay: window(windows.sevenDay))
    }
}
