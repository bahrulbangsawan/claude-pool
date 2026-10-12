import Foundation

enum ShellIntegrationStatus: Equatable, Sendable {
    case installed
    case notInstalled
    case outdated
    case unsupportedShell(String)

    var label: String {
        switch self {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        case .outdated: "Outdated"
        case let .unsupportedShell(shell): "Unsupported shell (\(shell)) — copy the snippet manually"
        }
    }
}

enum ShellIntegrationError: Error, LocalizedError {
    case unsupportedShell(String)
    case unreadable(String, String)
    case unbalancedMarkers(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedShell(shell): "Automatic install supports zsh and bash only (login shell is \(shell)). Use Copy Snippet and add it by hand."
        case let .unreadable(path, reason): "Could not read \(path): \(reason)"
        case let .unbalancedMarkers(path): "\(path) has a claude-pool start marker without an end marker. Fix it by hand, then retry."
        }
    }
}

/// Installs the marker-delimited `claude` shell function into ~/.zshrc or ~/.bash_profile.
struct ShellIntegrationService: Sendable {
    static let beginMarker = "# >>> claude-pool >>>"
    static let endMarker = "# <<< claude-pool <<<"

    /// The exact block, including its final newline.
    static let snippet = """
    # >>> claude-pool >>>
    # Managed by Claude Pool. Remove this block or use the app's Uninstall button.
    claude() {
      if [[ -z "${CLAUDE_CONFIG_DIR-}" ]]; then
        local _cp_dir
        _cp_dir="$(cat "$HOME/.claude-pool/active" 2>/dev/null)"
        if [[ -n "$_cp_dir" && -d "$_cp_dir" ]]; then
          CLAUDE_CONFIG_DIR="$_cp_dir" command claude "$@"
          return
        fi
      fi
      command claude "$@"
    }
    # <<< claude-pool <<<

    """

    let home: URL
    let loginShell: String

    /// Reads the user's login shell from the password database.
    static func currentLoginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    var shellName: String { URL(fileURLWithPath: loginShell).lastPathComponent }

    /// ~/.zshrc for zsh, ~/.bash_profile for bash, nil otherwise.
    var targetFile: URL? {
        switch shellName {
        case "zsh": home.appendingPathComponent(".zshrc")
        case "bash": home.appendingPathComponent(".bash_profile")
        default: nil
        }
    }

    func status() -> ShellIntegrationStatus {
        guard let file = targetFile else { return .unsupportedShell(shellName) }
        guard let text = try? String(contentsOf: Self.resolved(file), encoding: .utf8) else { return .notInstalled }
        guard let range = Self.blockRange(in: text) else { return .notInstalled }
        return String(text[range]) == Self.snippet ? .installed : .outdated
    }

    /// Backs up the target, then appends the block or replaces an existing one in place.
    /// Returns the backup URL (nil when the file did not exist yet).
    @discardableResult
    func install(now: Date = Date()) throws -> URL? {
        guard let file = targetFile else { throw ShellIntegrationError.unsupportedShell(shellName) }
        let target = Self.resolved(file)
        let existing = try Self.read(target)
        let backup = try existing.map { try Self.backup($0.data, of: target, now: now) }

        var text = existing?.text ?? ""
        if let range = Self.blockRange(in: text) {
            text.replaceSubrange(range, with: Self.snippet)
        } else if text.contains(Self.beginMarker) {
            throw ShellIntegrationError.unbalancedMarkers(target.path)
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += Self.snippet
        }
        try Self.write(text, to: target, permissions: existing?.permissions ?? 0o644)
        return backup
    }

    /// Backs up the target, then removes only the marked block.
    @discardableResult
    func uninstall(now: Date = Date()) throws -> URL? {
        guard let file = targetFile else { throw ShellIntegrationError.unsupportedShell(shellName) }
        let target = Self.resolved(file)
        guard let existing = try Self.read(target) else { return nil }
        guard let range = Self.blockRange(in: existing.text) else { return nil }
        let backup = try Self.backup(existing.data, of: target, now: now)
        var text = existing.text
        text.removeSubrange(range)
        try Self.write(text, to: target, permissions: existing.permissions)
        return backup
    }

    // MARK: - Helpers

    /// From the start of the begin-marker line through the end-marker line and its newline.
    static func blockRange(in text: String) -> Range<String.Index>? {
        guard let begin = text.range(of: beginMarker) else { return nil }
        let lineStart = text[..<begin.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        guard let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) else { return nil }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return lineStart..<upper
    }

    /// Writes through symlinks (dotfile managers) instead of replacing the link.
    static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    private struct Existing {
        var data: Data
        var text: String
        var permissions: Int
    }

    private static func read(_ url: URL) throws -> Existing? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
            return Existing(data: data, text: String(decoding: data, as: UTF8.self), permissions: permissions)
        } catch {
            throw ShellIntegrationError.unreadable(url.path, error.localizedDescription)
        }
    }

    private static func backup(_ data: Data, of url: URL, now: Date) throws -> URL {
        var backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).claude-pool.bak-\(Timestamp.string(now))")
        var counter = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).claude-pool.bak-\(Timestamp.string(now))_\(counter)")
            counter += 1
        }
        try AtomicFile.write(data, to: backup, permissions: 0o600)
        return backup
    }

    private static func write(_ text: String, to url: URL, permissions: Int) throws {
        try AtomicFile.write(Data(text.utf8), to: url, permissions: mode_t(permissions & 0o7777))
    }
}

/// `yyyyMMdd-HHmmss` in local time, for backup file names.
enum Timestamp {
    static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
