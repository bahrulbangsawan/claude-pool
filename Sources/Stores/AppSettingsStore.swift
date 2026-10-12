import Foundation
import Observation

/// App preferences, persisted to ~/Library/Application Support/ClaudePool/settings.json (0600).
@MainActor
@Observable
final class AppSettingsStore {
    var settings = AppSettings() {
        didSet { if settings != oldValue { save() } }
    }
    var lastError: String?

    let paths: Paths

    init(paths: Paths) {
        self.paths = paths
    }

    func load() {
        guard let data = try? Data(contentsOf: paths.appSettingsFile) else { return }
        do {
            settings = try ProfileStore.decoder.decode(AppSettings.self, from: data)
        } catch {
            lastError = "Could not read app settings; using defaults."
        }
    }

    private func save() {
        do {
            try AtomicFile.ensureDirectory(paths.appSupport, permissions: 0o700)
            try AtomicFile.write(try ProfileStore.encoder.encode(settings), to: paths.appSettingsFile, permissions: 0o600)
        } catch {
            lastError = "Could not save app settings: \(error.localizedDescription)"
        }
    }
}
