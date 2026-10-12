import Foundation

/// Runs the user's original status line command with the same stdin bytes.
enum ChainRunner {
    static let timeout: TimeInterval = 2

    /// Returns the command's stdout when it exits 0 within the timeout; otherwise nil,
    /// so the status line shows nothing, matching how Claude Code treats a failing command.
    static func run(command: String, input: Data, timeout: TimeInterval = ChainRunner.timeout) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // Inherited environment: the original command sees what Claude Code gave us.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("claude-pool-collector: could not start the original status line command\n".utf8))
            return nil
        }

        let writer = stdinPipe.fileHandleForWriting
        DispatchQueue.global().async {
            // EPIPE is ignored (SIGPIPE is disabled in main); the command may not read stdin.
            try? writer.write(contentsOf: input)
            try? writer.close()
        }

        let output = OutputBuffer()
        let readDone = DispatchSemaphore(value: 0)
        let reader = stdoutPipe.fileHandleForReading
        DispatchQueue.global().async {
            output.set((try? reader.readToEnd()) ?? Data())
            readDone.signal()
        }

        let deadline = DispatchTime.now() + timeout
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.2)
            }
            FileHandle.standardError.write(Data("claude-pool-collector: original status line command timed out\n".utf8))
            return nil
        }
        // A background grandchild may keep stdout open; do not wait past the deadline for it.
        _ = readDone.wait(timeout: max(deadline, .now() + 0.05))
        guard process.terminationStatus == 0 else { return nil }
        return output.get()
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
