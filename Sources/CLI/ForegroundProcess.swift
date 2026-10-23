import Darwin
import Foundation

/// A program to start in the user's terminal.
struct ProgramRun: Equatable, Sendable {
    var path: String
    /// Including the program name (`argv[0]`).
    var arguments: [String]
    var environment: [String: String]
    var directory: String?
}

/// Starts programs attached to the terminal claude-pool runs in, the way a shell does.
enum ForegroundProcess {
    /// Replaces this process with the program (`exec`). Returns only if that failed, with errno.
    static func exec(_ run: ProgramRun) -> Int32 {
        if let directory = run.directory, chdir(directory) != 0 { return errno }
        return withCStrings(run.arguments) { argv in
            withCStrings(environmentStrings(run.environment)) { envp in
                execve(run.path, argv, envp)
                return errno
            }
        }
    }

    /// Runs the program and waits for it. Ctrl-C and Ctrl-\ go to the program, as in a shell, and
    /// leave claude-pool running so it can report the result. Returns the exit status (128 + the
    /// signal number when a signal ended it, 127 when it could not start).
    static func run(_ run: ProgramRun) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGQUIT)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, previousInterrupt)
            signal(SIGQUIT, previousQuit)
        }

        var pid = pid_t()
        let started = withCStrings(run.arguments) { argv in
            withCStrings(environmentStrings(run.environment)) { envp in
                posix_spawn(&pid, run.path, nil, &attributes, argv, envp)
            }
        }
        guard started == 0 else { return 127 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return 1 }
        }
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift doesn't import.
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    private static func environmentStrings(_ environment: [String: String]) -> [String] {
        environment.map { "\($0.key)=\($0.value)" }
    }

    private static func withCStrings<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}
