import Foundation
import Testing
@testable import ClaudePool

@MainActor
@Suite struct ProfileStoreTests {
    let temp: TempDirectory
    let store: ProfileStore

    init() throws {
        temp = try TempDirectory()
        store = ProfileStore(paths: temp.paths)
        store.load()
    }

    private func reloaded() -> ProfileStore {
        let fresh = ProfileStore(paths: temp.paths)
        fresh.load()
        return fresh
    }

    private func dir(_ name: String) -> String {
        temp.paths.userHome.appendingPathComponent(name).path
    }

    @Test func createsDefaultProfile() throws {
        #expect(store.profiles.count == 1)
        let defaultProfile = try #require(store.defaultProfile)
        #expect(defaultProfile.isDefault)
        #expect(defaultProfile.configDir == temp.paths.userHome.appendingPathComponent(".claude").path)
        #expect(defaultProfile.configDirEnvironmentValue == nil)
        #expect(store.activeProfileID == defaultProfile.id)
        #expect(permissions(of: temp.paths.profilesFile) == 0o600)
    }

    @Test func persistsProfiles() throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        let fresh = reloaded()
        #expect(fresh.profiles.map(\.id) == store.profiles.map(\.id))
        #expect(fresh.profile(id: work.id) == work)
    }

    @Test func addCreatesDirectoryWith0700() throws {
        let profile = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: profile.configDir, isDirectory: &isDir) && isDir.boolValue)
        #expect(permissions(of: profile.configURL) == 0o700)
    }

    @Test func defaultIsUndeletable() throws {
        let id = try #require(store.defaultProfile?.id)
        #expect(throws: ProfileValidationError.defaultNotDeletable) {
            try store.delete(id, moveDirectoryToTrash: false)
        }
        #expect(store.profiles.count == 1)
    }

    @Test func enforcesUniqueness() throws {
        try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        #expect(throws: ProfileValidationError.nameTaken) { try store.add(name: "work", slug: "work2", configDir: dir(".claude-w2")) }
        #expect(throws: ProfileValidationError.slugTaken) { try store.add(name: "Work 2", slug: "work", configDir: dir(".claude-w2")) }
        #expect(throws: ProfileValidationError.directoryInUse("work")) { try store.add(name: "Other", slug: "other", configDir: dir(".claude-work")) }
        #expect(throws: ProfileValidationError.directoryInUse("default")) { try store.add(name: "Other", slug: "other", configDir: dir(".claude")) }
        #expect(throws: ProfileValidationError.directoryNotAbsolute) { try store.add(name: "Other", slug: "other", configDir: "relative/dir") }
        #expect(throws: ProfileValidationError.slugInvalid) { try store.add(name: "Other", slug: "Bad Slug", configDir: dir(".claude-o")) }
        #expect(throws: ProfileValidationError.nameEmpty) { try store.add(name: "   ", slug: "x", configDir: dir(".claude-x")) }
        #expect(throws: ProfileValidationError.nameEmpty) { try store.add(name: "★ — !", slug: "x", configDir: dir(".claude-x")) }
        #expect(throws: ProfileValidationError.nameTaken) { try store.add(name: "WORK!", slug: "x", configDir: dir(".claude-x")) }
        #expect(throws: ProfileValidationError.nameTooLong) { try store.add(name: String(repeating: "n", count: 33), slug: "x", configDir: dir(".claude-x")) }
        #expect(store.profiles.count == 2)
    }

    @Test func setActiveWritesPointer() throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        store.setActive(work.id)
        #expect(try store.pointer.read() == work.configDir)
        #expect(reloaded().activeProfileID == work.id)
        store.setActive(try #require(store.defaultProfile?.id))
        #expect(try store.pointer.read() == nil)
        #expect(try Data(contentsOf: temp.paths.pool.activePointer).isEmpty)
    }

    @Test func deletingActiveProfileResetsToDefault() throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        store.setActive(work.id)
        try store.delete(work.id, moveDirectoryToTrash: false)
        #expect(store.activeProfileID == store.defaultProfile?.id)
        #expect(try store.pointer.read() == nil)
        #expect(FileManager.default.fileExists(atPath: work.configDir), "Remove profile only keeps the directory")
    }

    @Test func deleteCanMoveDirectoryToTrash() throws {
        var trashed: [URL] = []
        let store = ProfileStore(paths: temp.paths, trash: { trashed.append($0) })
        store.load()
        let work = try store.add(name: "Trashme", slug: "trashme", configDir: dir(".claude-trashme"))
        try store.delete(work.id, moveDirectoryToTrash: true)
        #expect(trashed == [work.configURL])
        #expect(store.profile(id: work.id) == nil)
    }

    @Test func removeOnlyNeverTrashes() throws {
        var trashed: [URL] = []
        let store = ProfileStore(paths: temp.paths, trash: { trashed.append($0) })
        store.load()
        let work = try store.add(name: "Keep", slug: "keep", configDir: dir(".claude-keep"))
        try store.delete(work.id, moveDirectoryToTrash: false)
        #expect(trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: work.configDir))
    }

    @Test func reorderWritesSortIndex() throws {
        let a = try store.add(name: "A", slug: "a", configDir: dir(".claude-a"))
        let b = try store.add(name: "B", slug: "b", configDir: dir(".claude-b"))
        let defaultID = try #require(store.defaultProfile?.id)
        // [Default, A, B] → move B to the top → [B, Default, A]
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.profiles.map(\.id) == [b.id, defaultID, a.id])
        #expect(store.profiles.map(\.sortIndex) == [0, 1, 2])
        #expect(reloaded().profiles.map(\.id) == [b.id, defaultID, a.id])
        // Move Default to the end.
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        #expect(store.profiles.map(\.id) == [b.id, a.id, defaultID])
    }

    @Test func unknownPointerDirectoryIsReported() throws {
        try store.pointer.write("/somewhere/else")
        store.reloadActive()
        #expect(store.activeProfileID == nil)
        #expect(store.unknownActiveDirectory == "/somewhere/else")
    }

    @Test func updateValidatesAndKeepsDefaultDirectory() throws {
        var defaultProfile = try #require(store.defaultProfile)
        defaultProfile.configDir = "/elsewhere"
        defaultProfile.name = "Personal"
        try store.update(defaultProfile)
        #expect(store.defaultProfile?.name == "personal")
        #expect(store.defaultProfile?.configDir == temp.paths.userHome.appendingPathComponent(".claude").path)
        var work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        work.name = "personal"
        #expect(throws: ProfileValidationError.nameTaken) { try store.update(work) }
    }

    @Test func namesAreSavedInKebabCase() throws {
        let added = try store.add(name: "  My Work — Client #2 ", slug: "client", configDir: dir(".claude-client"))
        #expect(added.name == "my-work-client-2")
        var renamed = added
        renamed.name = "Café Ünïon"
        try store.update(renamed)
        #expect(reloaded().profile(id: added.id)?.name == "cafe-union")
        #expect(store.defaultProfile?.name == "default")
    }

    @Test func olderNamesAreConvertedOnLoad() throws {
        let profiles = [
            Profile.makeDefault(home: temp.paths.userHome),
            Profile(id: UUID(), name: "Work", slug: "work", configDir: dir(".claude-work"), colorHex: "#0A84FF", isDefault: false,
                    trackingEnabled: false, originalStatusLine: nil, sortIndex: 1, createdAt: Date(timeIntervalSince1970: 1)),
            Profile(id: UUID(), name: "work ", slug: "work-b", configDir: dir(".claude-work-b"), colorHex: "#0A84FF", isDefault: false,
                    trackingEnabled: false, originalStatusLine: nil, sortIndex: 2, createdAt: Date(timeIntervalSince1970: 2)),
            Profile(id: UUID(), name: "★", slug: "star", configDir: dir(".claude-star"), colorHex: "#0A84FF", isDefault: false,
                    trackingEnabled: false, originalStatusLine: nil, sortIndex: 3, createdAt: Date(timeIntervalSince1970: 3)),
        ]
        var legacyDefault = profiles[0]
        legacyDefault.name = "Default"
        try ProfileStore.encoder.encode([legacyDefault] + profiles.dropFirst()).write(to: temp.paths.profilesFile)

        let loaded = reloaded()
        #expect(loaded.profiles.map(\.name) == ["default", "work", "work-2", "star"])
        // Written back, so the next load (and the collector's view) agrees.
        let onDisk = try ProfileStore.decoder.decode([Profile].self, from: Data(contentsOf: temp.paths.profilesFile))
        #expect(onDisk.map(\.name) == ["default", "work", "work-2", "star"])
    }
}
