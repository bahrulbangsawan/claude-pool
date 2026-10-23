import Foundation
import Observation

enum ProfileValidationError: Error, LocalizedError, Equatable {
    case nameEmpty
    case nameTooLong
    case nameTaken
    case slugInvalid
    case slugTaken
    case directoryNotAbsolute
    case directoryInUse(String)
    case defaultNotDeletable
    case notFound

    var errorDescription: String? {
        switch self {
        case .nameEmpty: "Enter a name with at least one letter or digit."
        case .nameTooLong: "Names can be at most \(Profile.maxNameLength) characters."
        case .nameTaken: "Another profile already uses this name."
        case .slugInvalid: "Slugs use lowercase letters, digits and single hyphens (a-z, 0-9, -)."
        case .slugTaken: "Another profile already uses this slug."
        case .directoryNotAbsolute: "The directory must be an absolute path."
        case let .directoryInUse(name): "The profile “\(name)” already uses this directory."
        case .defaultNotDeletable: "The Default profile cannot be removed."
        case .notFound: "That profile no longer exists."
        }
    }
}

/// Profiles and the active selection. Persists to profiles.json and the pointer file.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [Profile] = []
    /// Active profile; nil when the pointer names a directory no profile owns.
    private(set) var activeProfileID: UUID?
    private(set) var unknownActiveDirectory: String?
    var lastError: String?
    /// Called after profiles.json is written (a profile was added, edited, removed or reordered).
    @ObservationIgnored var onSave: (() -> Void)?

    let paths: Paths
    let pointer: PointerFileService
    @ObservationIgnored private let now: () -> Date
    /// Moves a directory to the Trash; injectable so tests never touch the real Trash.
    @ObservationIgnored private let trash: (URL) throws -> Void

    init(
        paths: Paths,
        now: @escaping () -> Date = Date.init,
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.paths = paths
        self.pointer = PointerFileService(pool: paths.pool)
        self.now = now
        self.trash = trash
    }

    var defaultProfile: Profile? { profiles.first(where: \.isDefault) }
    var activeProfile: Profile? { activeProfileID.flatMap(profile(id:)) }

    func profile(id: UUID) -> Profile? { profiles.first { $0.id == id } }

    // MARK: Loading

    func load() {
        do {
            if FileManager.default.fileExists(atPath: paths.profilesFile.path) {
                let data = try Data(contentsOf: paths.profilesFile)
                profiles = try Self.decoder.decode([Profile].self, from: data)
            }
        } catch {
            lastError = "Couldn't read profiles.json: \(error.localizedDescription). Your profiles were reset to Default; restore the file from a backup to recover them."
        }
        let renamed = normalize()
        if !profiles.contains(where: \.isDefault) {
            profiles.insert(Profile.makeDefault(home: paths.userHome, now: Self.wholeSeconds(now())), at: 0)
            reindex()
            save()
        } else if renamed {
            save()
        }
        reloadActive()
    }

    /// Reads the pointer file to decide which profile is active.
    func reloadActive() {
        do {
            let value = try pointer.read()
            unknownActiveDirectory = nil
            if let value {
                if let match = profiles.first(where: { !$0.isDefault && Paths.canonical($0.configDir) == Paths.canonical(value) }) {
                    activeProfileID = match.id
                } else {
                    activeProfileID = nil
                    unknownActiveDirectory = value
                }
            } else {
                activeProfileID = defaultProfile?.id
            }
        } catch {
            activeProfileID = defaultProfile?.id
            lastError = "Could not read the active profile pointer: \(error.localizedDescription)"
        }
    }

    // MARK: Mutations

    func setActive(_ id: UUID) {
        guard let profile = profile(id: id) else { return }
        do {
            try pointer.setActive(profile)
            activeProfileID = id
            unknownActiveDirectory = nil
            lastError = nil
        } catch {
            lastError = "Couldn't switch to \(profile.name): \(error.localizedDescription). Check that ~/.claude-pool is writable, then try again."
        }
    }

    /// Checks the name as it will be saved, that is after `Profile.normalizedName`.
    func validate(name: String, slug: String, configDir: String, excluding id: UUID? = nil) throws {
        let normalized = Profile.normalizedName(name)
        guard !normalized.isEmpty else { throw ProfileValidationError.nameEmpty }
        guard normalized.count <= Profile.maxNameLength else { throw ProfileValidationError.nameTooLong }
        let others = profiles.filter { $0.id != id }
        guard !others.contains(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            throw ProfileValidationError.nameTaken
        }
        guard Slug.isValid(slug) else { throw ProfileValidationError.slugInvalid }
        guard !others.contains(where: { $0.slug == slug }) else { throw ProfileValidationError.slugTaken }
        guard configDir.hasPrefix("/") else { throw ProfileValidationError.directoryNotAbsolute }
        if let owner = others.first(where: { Paths.canonical($0.configDir) == Paths.canonical(configDir) }) {
            throw ProfileValidationError.directoryInUse(owner.name)
        }
    }

    /// Adds a profile and creates its directory (0700) if needed.
    @discardableResult
    func add(name: String, slug: String, configDir: String, colorHex: String? = nil) throws -> Profile {
        // Reject relative paths before standardizing, which would resolve them against the cwd.
        guard configDir.hasPrefix("/") else { throw ProfileValidationError.directoryNotAbsolute }
        let dir = URL(fileURLWithPath: configDir).standardizedFileURL.path
        try validate(name: name, slug: slug, configDir: dir)
        try AtomicFile.ensureDirectory(URL(fileURLWithPath: dir, isDirectory: true), permissions: 0o700)
        let profile = Profile(
            id: UUID(),
            name: Profile.normalizedName(name),
            slug: slug,
            configDir: dir,
            colorHex: colorHex ?? ProfileColor.presets[profiles.count % ProfileColor.presets.count].hex,
            isDefault: false,
            trackingEnabled: false,
            originalStatusLine: nil,
            sortIndex: (profiles.map(\.sortIndex).max() ?? -1) + 1,
            createdAt: Self.wholeSeconds(now())
        )
        profiles.append(profile)
        save()
        return profile
    }

    /// Saves edits to name, slug, directory, color or tracking fields.
    func update(_ profile: Profile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw ProfileValidationError.notFound }
        var updated = profile
        if updated.isDefault { updated.configDir = profiles[index].configDir }
        try validate(name: updated.name, slug: updated.slug, configDir: updated.configDir, excluding: updated.id)
        updated.name = Profile.normalizedName(updated.name)
        let wasActive = activeProfileID == updated.id
        let dirChanged = profiles[index].configDir != updated.configDir
        profiles[index] = updated
        save()
        if wasActive, dirChanged { setActive(updated.id) }
    }

    /// Removes a profile. Optionally moves its directory to the Trash (never deletes it).
    func delete(_ id: UUID, moveDirectoryToTrash: Bool) throws {
        guard let profile = profile(id: id) else { throw ProfileValidationError.notFound }
        guard !profile.isDefault else { throw ProfileValidationError.defaultNotDeletable }
        if moveDirectoryToTrash, FileManager.default.fileExists(atPath: profile.configDir) {
            try trash(profile.configURL)
        }
        let wasActive = activeProfileID == id
        profiles.removeAll { $0.id == id }
        reindex()
        save()
        if wasActive, let defaultID = defaultProfile?.id { setActive(defaultID) }
    }

    /// Reorders by the user's drag; writes sortIndex.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = profiles
        let moving = source.sorted().map { reordered[$0] }
        for index in source.sorted(by: >) { reordered.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: max(0, min(insertAt, reordered.count)))
        profiles = reordered
        reindex()
        save()
    }

    // MARK: Persistence

    /// Returns whether a name had to change.
    private func normalize() -> Bool {
        profiles.sort { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        // Exactly one Default.
        var seenDefault = false
        for index in profiles.indices where profiles[index].isDefault {
            if seenDefault { profiles[index].isDefault = false }
            seenDefault = true
        }
        if let index = profiles.firstIndex(where: \.isDefault) {
            profiles[index].configDir = paths.defaultConfigDir.path
        }
        // Names are kebab-case. Earlier versions took any text ("Work", "Client — Northwind"), so
        // those are converted once, in order, with -2, -3… where two would come out the same.
        var renamed = false
        var taken: Set<String> = []
        for index in profiles.indices {
            var base = Slug.make(from: profiles[index].name)
            if base.isEmpty { base = Slug.isValid(profiles[index].slug) ? profiles[index].slug : "profile" }
            var name = base
            var counter = 2
            while taken.contains(name) {
                name = Slug.make(from: "\(base.prefix(Profile.maxNameLength - 4))-\(counter)")
                counter += 1
            }
            taken.insert(name)
            if profiles[index].name != name {
                profiles[index].name = name
                renamed = true
            }
        }
        return renamed
    }

    private func reindex() {
        for index in profiles.indices { profiles[index].sortIndex = index }
    }

    func save() {
        do {
            try AtomicFile.ensureDirectory(paths.appSupport, permissions: 0o700)
            let data = try Self.encoder.encode(profiles)
            try AtomicFile.write(data, to: paths.profilesFile, permissions: 0o600)
            onSave?()
        } catch {
            lastError = "Couldn't save profiles: \(error.localizedDescription). Check that ~/Library/Application Support/ClaudePool is writable, then try again."
        }
    }

    /// profiles.json stores ISO-8601 dates, which carry whole seconds.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
