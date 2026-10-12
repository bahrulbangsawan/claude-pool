import Foundation
@testable import ClaudePool

/// A unique temporary directory, removed on deinit. Tests never touch the real home directory.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-pool-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var paths: Paths { Paths.temporary(root: url) }

    func file(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    @discardableResult
    func write(_ text: String, to relative: String) throws -> URL {
        let target = file(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }
}

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

func permissions(of url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
}

func readText(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

struct ProcessOutput {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var elapsed: TimeInterval

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs a process synchronously with stdin bytes; used for subprocess-level tests.
func runProcess(_ executable: URL, _ arguments: [String], environment: [String: String], stdin: Data = Data()) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let input = Pipe(), output = Pipe(), error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    let start = Date()
    try process.run()
    let writer = input.fileHandleForWriting
    DispatchQueue.global().async {
        try? writer.write(contentsOf: stdin)
        try? writer.close()
    }
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessOutput(status: process.terminationStatus, stdout: out, stderr: err, elapsed: Date().timeIntervalSince(start))
}

/// Locates the built collector: env override (Xcode scheme), then next to the test bundle, then .build.
func collectorBinary() throws -> URL {
    let fm = FileManager.default
    if let path = ProcessInfo.processInfo.environment["CLAUDE_POOL_COLLECTOR_PATH"], fm.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(PoolPaths.collectorName)
        if fm.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    let root = Fixtures.directory.deletingLastPathComponent().deletingLastPathComponent()
    for relative in [".build/debug", ".build/arm64-apple-macosx/debug", ".build/release"] {
        let candidate = root.appendingPathComponent(relative).appendingPathComponent(PoolPaths.collectorName)
        if fm.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "claude-pool-collector binary not found; run swift build first"])
}
