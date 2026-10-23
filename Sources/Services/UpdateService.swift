import CryptoKit
import Darwin
import Foundation

enum UpdateError: Error, LocalizedError, Equatable {
    case checkFailed(String)
    case noDiskImage
    case downloadFailed(String)
    case checksumMismatch
    case invalidApp(String)
    case cannotInstall(String)

    var errorDescription: String? {
        switch self {
        case let .checkFailed(reason): "Couldn't check for updates: \(reason)"
        case .noDiskImage: "The latest release has no disk image with a checksum, so it can't be installed automatically. Download it from the release page."
        case let .downloadFailed(reason): "Couldn't download the update: \(reason)"
        case .checksumMismatch: "The downloaded update doesn't match the release's SHA-256 checksum, so it wasn't installed."
        case let .invalidApp(reason): "The downloaded update wasn't installed: \(reason)"
        case let .cannotInstall(reason): "Couldn't install the update: \(reason)"
        }
    }
}

/// A dotted release version ("1.6.0", or a tag such as "v1.6.0"). Missing parts count as 0.
struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let fields = (text.hasPrefix("v") ? text.dropFirst() : Substring(text)).split(separator: ".", omittingEmptySubsequences: false)
        let parts = fields.compactMap { field in field.allSatisfy(\.isASCII) ? Int(field) : nil }
        guard !parts.isEmpty, parts.count == fields.count, parts.allSatisfy({ $0 >= 0 }) else { return nil }
        self.parts = parts
    }

    /// The running app's CFBundleShortVersionString.
    static var current: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// The latest GitHub release: its version, page, and the disk image with its SHA-256 checksum.
struct AppRelease: Equatable, Sendable {
    let version: AppVersion
    let pageURL: URL
    let diskImageURL: URL?
    let sha256: String?
}

/// What Settings › Updates and the menu bar panel show.
enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AppRelease)
    case installing(AppRelease)
    case failed(String)
}

/// Checks GitHub for a newer Claude Pool, downloads and verifies its disk image, and swaps the
/// app bundle in place. Network access goes through /usr/bin/curl, as herdr's installer does, so
/// the app links no networking API; nothing is sent beyond the request itself.
struct UpdateService: Sendable {
    static let repository = "bahrulbangsawan/claude-pool"
    static let latestReleaseURL = "https://api.github.com/repos/\(repository)/releases/latest"
    static let appName = "ClaudePool.app"

    let home: URL
    /// Where downloads are verified and staged; emptied before each download.
    let workDirectory: URL
    var runner: ProcessRunner = .shared
    var curl = URL(fileURLWithPath: "/usr/bin/curl")
    var releaseURL = Self.latestReleaseURL

    // MARK: - Check

    func latestRelease() async throws -> AppRelease {
        let result = try await runner.run(
            curl, arguments: ["-fsSL", "--connect-timeout", "10", "--max-time", "30",
                              "-H", "Accept: application/vnd.github+json", releaseURL],
            environment: environment, timeout: 40
        )
        if result.timedOut { throw UpdateError.checkFailed("GitHub didn't answer within 40 seconds.") }
        guard result.exitCode == 0 else { throw UpdateError.checkFailed(Self.curlFailure(result)) }
        guard let release = Self.release(from: result.stdout) else {
            throw UpdateError.checkFailed("GitHub's reply had no release version.")
        }
        return release
    }

    /// Decodes only the tag, the page URL and each asset's name, download URL and digest.
    static func release(from data: Data) -> AppRelease? {
        struct Reply: Decodable {
            struct Asset: Decodable {
                var name: String
                var browserDownloadUrl: URL
                var digest: String?
            }

            var tagName: String
            var htmlUrl: URL
            var assets: [Asset]?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(Reply.self, from: data), let version = AppVersion(reply.tagName) else { return nil }
        let image = reply.assets?.first { $0.name.hasSuffix(".dmg") }
        let sha256 = image?.digest.flatMap { digest -> String? in
            guard digest.hasPrefix("sha256:") else { return nil }
            let hex = digest.dropFirst("sha256:".count).lowercased()
            return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
        }
        return AppRelease(version: version, pageURL: reply.htmlUrl, diskImageURL: image?.browserDownloadUrl, sha256: sha256)
    }

    // MARK: - Download

    /// Downloads the disk image, checks its SHA-256, and copies the app out of it after checking
    /// its bundle identifier, version and code signature. Returns the staged app.
    func download(_ release: AppRelease, bundleIdentifier: String) async throws -> URL {
        guard let imageURL = release.diskImageURL, let expected = release.sha256 else { throw UpdateError.noDiskImage }
        let fm = FileManager.default
        try? fm.removeItem(at: workDirectory)
        try AtomicFile.ensureDirectory(workDirectory, permissions: 0o700)
        let image = workDirectory.appendingPathComponent("ClaudePool-\(release.version).dmg")
        let fetched = try await runner.run(
            curl, arguments: ["-fsSL", "--retry", "2", "--connect-timeout", "10", "--max-time", "300",
                              "-o", image.path, imageURL.absoluteString],
            environment: environment, timeout: 320
        )
        if fetched.timedOut { throw UpdateError.downloadFailed("it took longer than 5 minutes.") }
        guard fetched.exitCode == 0 else { throw UpdateError.downloadFailed(Self.curlFailure(fetched)) }
        guard CollectorInstaller.sha256(of: image) == expected else { throw UpdateError.checksumMismatch }

        let mount = workDirectory.appendingPathComponent("mount")
        let attached = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path], timeout: 60)
        guard attached.exitCode == 0 else { throw UpdateError.downloadFailed("the disk image couldn't be opened.") }
        let staged = workDirectory.appendingPathComponent(Self.appName)
        do {
            let app = mount.appendingPathComponent(Self.appName)
            try await verify(app, bundleIdentifier: bundleIdentifier, version: release.version)
            let copied = try await run("/usr/bin/ditto", [app.path, staged.path], timeout: 60)
            guard copied.exitCode == 0 else { throw UpdateError.downloadFailed("the app couldn't be copied out of the disk image.") }
        } catch {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 30)
            throw error
        }
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 30)
        try? fm.removeItem(at: image)
        return staged
    }

    /// The app must be Claude Pool (same bundle identifier), the release's version, and pass a
    /// strict code-signature check.
    func verify(_ app: URL, bundleIdentifier: String, version: AppVersion) async throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.invalidApp("the disk image doesn't contain \(Self.appName).")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.invalidApp("it isn't Claude Pool (different bundle identifier).")
        }
        guard (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == version else {
            throw UpdateError.invalidApp("its version doesn't match release \(version).")
        }
        let signature = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60)
        guard signature.exitCode == 0 else { throw UpdateError.invalidApp("its code signature is invalid.") }
    }

    /// Removes what the last update left behind (the staged app and the swap script).
    func cleanUp() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: - Install

    /// Copies the staged app next to `current`, then starts the swap script in its own session so
    /// it outlives Claude Pool. The caller quits; the script swaps the bundles and reopens the app.
    func install(_ staged: URL, over current: URL, waitingFor pid: pid_t, opener: String = "/usr/bin/open") async throws {
        let parent = current.deletingLastPathComponent()
        guard current.pathExtension == "app" else { throw UpdateError.cannotInstall("Claude Pool isn't running from an app bundle.") }
        guard !current.path.contains("/AppTranslocation/"), !current.path.hasPrefix("/Volumes/") else {
            throw UpdateError.cannotInstall("Claude Pool is running from the disk image. Move it to Applications first.")
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.cannotInstall("\(parent.path) isn't writable without an administrator password. Run the installer from the release page instead.")
        }
        let incoming = parent.appendingPathComponent(".\(current.deletingPathExtension().lastPathComponent)-update.app")
        try? FileManager.default.removeItem(at: incoming)
        let copied = try await run("/usr/bin/ditto", [staged.path, incoming.path], timeout: 60)
        guard copied.exitCode == 0 else { throw UpdateError.cannotInstall("the new version couldn't be copied to \(parent.path).") }

        let script = workDirectory.appendingPathComponent("install.sh")
        try AtomicFile.write(Data(Self.installScript.utf8), to: script, permissions: 0o700)
        try Self.spawnDetached(["/bin/sh", script.path, String(pid), incoming.path, current.path, opener])
    }

    /// Waits up to 30 s for the app to quit, swaps the bundles (restoring the old one if the swap
    /// fails), then reopens whichever app is in place.
    static let installScript = #"""
    #!/bin/sh
    pid=$1 incoming=$2 dest=$3 opener=$4
    old="$incoming.old"
    tries=0
    while kill -0 "$pid" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -le 150 ] || { rm -rf "$incoming"; exit 1; }
        sleep 0.2
    done
    rm -rf "$old"
    if mv "$dest" "$old"; then
        if mv "$incoming" "$dest"; then
            rm -rf "$old"
        else
            mv "$old" "$dest"
        fi
    fi
    rm -rf "$incoming"
    "$opener" "$dest"

    """#

    /// Starts a process in a new session (POSIX_SPAWN_SETSID), so it keeps running after Claude
    /// Pool quits.
    static func spawnDetached(_ arguments: [String]) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let variables = ["PATH=\(ChildEnvironment.basePath)", "LANG=en_US.UTF-8"]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = variables.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, arguments[0], nil, &attributes, argv, envp)
        guard status == 0 else { throw UpdateError.cannotInstall(String(cString: strerror(status))) }
    }

    // MARK: - Helpers

    private var environment: [String: String] {
        ["HOME": home.path, "PATH": ChildEnvironment.basePath, "LANG": "en_US.UTF-8"]
    }

    private func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await runner.run(URL(fileURLWithPath: tool), arguments: arguments, environment: environment, timeout: timeout)
    }

    /// curl's own message ("curl: (22) The requested URL returned error: 404") without the prefix.
    static func curlFailure(_ result: ProcessResult) -> String {
        let text = String(decoding: result.stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .replacingOccurrences(of: #"^curl: \(\d+\) "#, with: "", options: .regularExpression)
        return text.flatMap { $0.isEmpty ? nil : $0 } ?? "curl exited with code \(result.exitCode)."
    }
}
