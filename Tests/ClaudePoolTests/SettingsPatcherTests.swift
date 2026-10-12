import Foundation
import Testing
@testable import ClaudePool

@Suite struct SettingsPatcherTests {
    let temp: TempDirectory
    let pool: PoolPaths
    let profile: Profile
    let collectorPath: String

    init() throws {
        temp = try TempDirectory()
        pool = temp.paths.pool
        var profile = Profile.makeDefault(home: temp.paths.userHome)
        profile.isDefault = false
        profile.configDir = temp.paths.userHome.appendingPathComponent(".claude-work").path
        self.profile = profile
        try FileManager.default.createDirectory(at: profile.configURL, withIntermediateDirectories: true)
        collectorPath = pool.installedCollector.path
    }

    var settingsURL: URL { SettingsPatcher.settingsURL(for: profile) }

    private func patcher(clock: @escaping @Sendable () -> Date = { Date() }) -> SettingsPatcher {
        SettingsPatcher(pool: pool, clock: clock)
    }

    private func json(_ url: URL) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: settingsURL)
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: pool.backups(for: profile.id).path)) ?? []).sorted()
    }

    private func enabled(_ original: String?) -> Profile {
        var copy = profile
        copy.trackingEnabled = true
        copy.originalStatusLine = original
        return copy
    }

    @Test func missingFileIsTreatedAsEmptyObject() throws {
        let result = try patcher().enable(profile, collectorPath: collectorPath)
        #expect(result == .patched(originalStatusLine: nil))
        let object = try json(settingsURL)
        #expect(object.allKeys as? [String] == ["statusLine"])
        let statusLine = try #require(object["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")
        #expect(statusLine["command"] as? String == "'\(collectorPath)' --profile \(profile.id.uuidString)")
        #expect(!FileManager.default.fileExists(atPath: pool.chainCommand(for: profile.id).path))
        #expect(backups().isEmpty, "nothing to back up when the file did not exist")
    }

    @Test func invalidJSONIsRefusedAndFileUnchanged() throws {
        for text in ["{ not json", "[1, 2, 3]", "\"just a string\""] {
            try write(text)
            #expect(throws: SettingsPatcherError.self) { try patcher().enable(profile, collectorPath: collectorPath) }
            #expect(readText(settingsURL) == text)
        }
        #expect(backups().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pool.chainCommand(for: profile.id).path))
    }

    @Test func unrelatedKeysArePreserved() throws {
        let original = """
        {"model":"opus","permissions":{"allow":["Bash(ls:*)"],"deny":[]},"env":{"FOO":"1"},
         "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]},
         "includeCoAuthoredBy":false,"cleanupPeriodDays":30,"ratio":1.5}
        """
        try write(original)
        let before = try json(settingsURL)
        try patcher().enable(profile, collectorPath: collectorPath)
        let after = try json(settingsURL).mutableCopy() as! NSMutableDictionary
        after.removeObject(forKey: "statusLine")
        #expect(after == before)

        try patcher().disable(enabled(nil))
        #expect(try json(settingsURL) == before)
    }

    @Test func existingStatusLineIsSavedChainedAndRestored() throws {
        try write(#"{"theme":"dark","statusLine":{"type":"command","command":"~/bin/my status.sh --x 'y'","padding":2}}"#)
        let originalValue = try #require(try json(settingsURL)["statusLine"] as? NSDictionary)

        let result = try patcher().enable(profile, collectorPath: collectorPath)
        guard case let .patched(saved?) = result else {
            Issue.record("expected the original value to be saved")
            return
        }
        #expect(SettingsPatcher.parseFragment(saved) as? NSDictionary == originalValue)
        #expect(readText(pool.chainCommand(for: profile.id)) == "~/bin/my status.sh --x 'y'")
        #expect(permissions(of: pool.chainCommand(for: profile.id)) == 0o600)

        let patched = try #require(try json(settingsURL)["statusLine"] as? [String: Any])
        #expect(patched["padding"] as? Int == 2)
        #expect((patched["command"] as? String)?.contains(PoolPaths.collectorName) == true)

        try patcher().disable(enabled(saved))
        let restored = try json(settingsURL)
        #expect(restored["statusLine"] as? NSDictionary == originalValue)
        #expect(restored["theme"] as? String == "dark")
        #expect(!FileManager.default.fileExists(atPath: pool.chainCommand(for: profile.id).path))
    }

    @Test func disableRemovesKeyWhenThereWasNoOriginal() throws {
        try write(#"{"model":"sonnet"}"#)
        try patcher().enable(profile, collectorPath: collectorPath)
        try patcher().disable(enabled(nil))
        #expect(try json(settingsURL) == ["model": "sonnet"] as NSDictionary)
    }

    @Test func paddingIsCarriedOver() throws {
        try write(#"{"statusLine":{"type":"command","command":"echo hi","padding":0}}"#)
        let preview = try patcher().previewEnable(profile, collectorPath: collectorPath)
        #expect(preview.after?.contains("\"padding\" : 0") == true)
        try patcher().enable(profile, collectorPath: collectorPath)
        let patched = try #require(try json(settingsURL)["statusLine"] as? [String: Any])
        #expect(patched["padding"] as? Int == 0)
    }

    @Test func chainFileOnlyForCommandType() throws {
        try write(#"{"statusLine":{"type":"static","text":"hello"}}"#)
        let result = try patcher().enable(profile, collectorPath: collectorPath)
        #expect(result == .patched(originalStatusLine: #"{"text":"hello","type":"static"}"#))
        #expect(!FileManager.default.fileExists(atPath: pool.chainCommand(for: profile.id).path))
    }

    @Test func enableTwiceIsANoOp() throws {
        try write(#"{"statusLine":{"type":"command","command":"echo a"}}"#)
        let first = try patcher().enable(profile, collectorPath: collectorPath)
        let bytes = try Data(contentsOf: settingsURL)
        #expect(try patcher().enable(profile, collectorPath: collectorPath) == .alreadyEnabled)
        #expect(try Data(contentsOf: settingsURL) == bytes)
        #expect(first != .alreadyEnabled)
        #expect(backups().count == 1)
    }

    @Test func detectsOverriddenState() throws {
        try write("{}")
        #expect(patcher().state(for: profile) == .disabled)
        try patcher().enable(profile, collectorPath: collectorPath)
        #expect(patcher().state(for: enabled(nil)) == .enabled)

        // The user runs /statusline, replacing the key.
        try write(#"{"statusLine":{"type":"command","command":"my-new-line"}}"#)
        #expect(patcher().state(for: enabled(nil)) == .overridden)
        #expect(patcher().state(for: profile) == .disabled)

        // Disabling leaves the user's newer value alone.
        try patcher().disable(enabled(nil))
        #expect((try json(settingsURL)["statusLine"] as? [String: Any])?["command"] as? String == "my-new-line")
    }

    @Test func otherProfilesCollectorIsNotThisProfiles() throws {
        let other = UUID()
        try write(#"{"statusLine":{"type":"command","command":"'\#(collectorPath)' --profile \#(other.uuidString)"}}"#)
        #expect(patcher().state(for: enabled(nil)) == .overridden)
    }

    @Test func backupHoldsOriginalBytesAndRotationKeepsTen() throws {
        let original = #"{"statusLine":{"type":"command","command":"echo 0"}}"#
        try write(original)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let counter = Counter()
        let patcher = patcher(clock: { base.addingTimeInterval(Double(counter.next())) })

        try patcher.enable(profile, collectorPath: collectorPath)
        let firstBackup = try #require(backups().first)
        #expect(readText(pool.backups(for: profile.id).appendingPathComponent(firstBackup)) == original)
        #expect(permissions(of: pool.backups(for: profile.id).appendingPathComponent(firstBackup)) == 0o600)

        for _ in 0..<7 {
            try patcher.disable(enabled(#"{"command":"echo 0","type":"command"}"#))
            try patcher.enable(profile, collectorPath: collectorPath)
        }
        let names = backups()
        #expect(names.count == 10)
        // The oldest five of 15 were pruned; the newest is kept.
        #expect(names.last == "settings-\(Timestamp.string(base.addingTimeInterval(14))).json")
        #expect(!names.contains(firstBackup))
    }

    @Test func backupNameCollisionsGetSuffix() throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let patcher = patcher(clock: { fixed })
        let a = try patcher.backup(Data("a".utf8), profileID: profile.id)
        let b = try patcher.backup(Data("b".utf8), profileID: profile.id)
        #expect(a != b)
        #expect(b.lastPathComponent.hasSuffix("_2.json"))
        #expect(backups() == [a.lastPathComponent, b.lastPathComponent])
    }

    @Test func missingDirectoryIsAnError() throws {
        var missing = profile
        missing.configDir = temp.file("nope").path
        #expect(throws: SettingsPatcherError.self) { try patcher().enable(missing, collectorPath: collectorPath) }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
