import CryptoKit
import Foundation

enum CollectorInstallerError: Error, LocalizedError {
    case bundledHelperMissing(String)

    var errorDescription: String? {
        switch self {
        case let .bundledHelperMissing(path): "The bundled collector helper is missing at \(path). Rebuild or reinstall Claude Pool."
        }
    }
}

enum CollectorInstallState: Equatable, Sendable {
    case upToDate
    case missing
    case outdated
    case bundledHelperMissing
}

/// Copies the bundled helper to ~/.claude-pool/bin so settings.json files keep working
/// even if the app is moved. Re-copied whenever the SHA-256 differs.
struct CollectorInstaller: Sendable {
    let pool: PoolPaths
    let bundledHelper: URL

    /// `Contents/Helpers/claude-pool-collector` inside the app, or next to the executable
    /// when running unbundled (e.g. `swift run`).
    static func bundledHelperURL(bundle: Bundle = .main) -> URL {
        let inBundle = bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(PoolPaths.collectorName)")
        if FileManager.default.fileExists(atPath: inBundle.path) { return inBundle }
        if let executable = bundle.executableURL {
            return executable.deletingLastPathComponent().appendingPathComponent(PoolPaths.collectorName)
        }
        return inBundle
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func state() -> CollectorInstallState {
        guard let bundled = Self.sha256(of: bundledHelper) else { return .bundledHelperMissing }
        guard let installed = Self.sha256(of: pool.installedCollector) else { return .missing }
        return bundled == installed ? .upToDate : .outdated
    }

    /// Installs or refreshes the helper. Returns true when a copy was made.
    @discardableResult
    func installIfNeeded() throws -> Bool {
        switch state() {
        case .upToDate: return false
        case .bundledHelperMissing: throw CollectorInstallerError.bundledHelperMissing(bundledHelper.path)
        case .missing, .outdated: break
        }
        try AtomicFile.ensureDirectory(pool.home, permissions: 0o700)
        try AtomicFile.ensureDirectory(pool.binDirectory, permissions: 0o700)
        let data = try Data(contentsOf: bundledHelper)
        // Temp file + rename: a status line run already in progress keeps its old inode.
        try AtomicFile.write(data, to: pool.installedCollector, permissions: 0o700)
        return true
    }

    /// Writes the summary/none choice the collector reads when no original status line exists.
    func writeOutputMode(_ mode: CollectorOutputMode) throws {
        try AtomicFile.ensureDirectory(pool.home, permissions: 0o700)
        try AtomicFile.write(Data(mode.rawValue.utf8), to: pool.collectorOutputSetting, permissions: 0o600)
    }
}
