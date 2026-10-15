import Foundation
import Testing
@testable import ClaudePool

@Suite struct SharedConfigSyncTests {
    let temp: TempDirectory
    let home: URL
    let primary: Profile
    let work: Profile
    let fresh: Profile

    init() throws {
        temp = try TempDirectory()
        home = temp.paths.userHome
        primary = Profile.makeDefault(home: home)
        work = Self.profile("work", home: home)
        fresh = Self.profile("fresh", home: home)
        for profile in [primary, work, fresh] {
            try FileManager.default.createDirectory(at: profile.configURL, withIntermediateDirectories: true)
        }
    }

    static func profile(_ name: String, home: URL) -> Profile {
        var profile = Profile.makeDefault(home: home)
        profile = Profile(id: UUID(), name: name, slug: name, configDir: home.appendingPathComponent(".claude-\(name)").path,
                          colorHex: profile.colorHex, isDefault: false, trackingEnabled: false, originalStatusLine: nil,
                          sortIndex: 1, createdAt: profile.createdAt)
        return profile
    }

    var profiles: [Profile] { [primary, work, fresh] }

    @discardableResult
    func sync() throws -> SharedConfigSync.Report {
        try SharedConfigSync(pool: temp.paths.pool, home: home).run(profiles: profiles)
    }

    func globalConfig(_ profile: Profile) -> URL { AccountDetailsReader.configFile(for: profile, home: home) }
    func settings(_ profile: Profile) -> URL { profile.configURL.appendingPathComponent("settings.json") }

    func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func read(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func mcpNames(_ profile: Profile) throws -> Set<String> {
        Set(((try read(globalConfig(profile))["mcpServers"] as? [String: Any]) ?? [:]).keys)
    }

    @Test func freshProfileGetsEveryMCPServer() throws {
        try write(["mcpServers": ["cloudflare": ["type": "http", "url": "https://example.test/mcp"]], "numStartups": 4], to: globalConfig(primary))
        try write(["mcpServers": ["local": ["command": "x"]], "oauthAccount": ["emailAddress": "w@example.test"]], to: globalConfig(work))
        try sync()
        for profile in profiles { #expect(try mcpNames(profile) == ["cloudflare", "local"]) }
        // Other keys are carried over untouched.
        #expect(try read(globalConfig(primary))["numStartups"] as? Int == 4)
        #expect((try read(globalConfig(work))["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "w@example.test")
    }

    @Test func profileAddedLaterIsFilledIn() throws {
        try write(["mcpServers": ["a": ["command": "a"]]], to: globalConfig(primary))
        _ = try SharedConfigSync(pool: temp.paths.pool, home: home).run(profiles: [primary, work])
        try sync()  // `fresh` joins with no state: nothing of it reads as deleted
        #expect(try mcpNames(fresh) == ["a"])
        #expect(try mcpNames(primary) == ["a"])
    }

    @Test func removalSpreadsOnlyAfterTheEntryWasSeen() throws {
        try write(["mcpServers": ["a": ["command": "a"], "b": ["command": "b"]]], to: globalConfig(primary))
        try sync()
        // A running session rewrites its file without the entry just added: not a removal.
        try write(["mcpServers": ["a": ["command": "a"]]], to: globalConfig(work))
        try sync()
        #expect(try mcpNames(primary) == ["a", "b"])
        #expect(try mcpNames(work) == ["a", "b"])
        try sync()  // the next run sees "b" on disk in `work`
        // Now `work` has held "b"; removing it there removes it everywhere.
        try write(["mcpServers": ["a": ["command": "a"]]], to: globalConfig(work))
        try sync()
        for profile in profiles { #expect(try mcpNames(profile) == ["a"]) }
        // And it may be added back later.
        try write(["mcpServers": ["a": ["command": "a"], "b": ["command": "b2"]]], to: globalConfig(fresh))
        try sync()
        for profile in profiles { #expect(try mcpNames(profile) == ["a", "b"]) }
    }

    @Test func settingsShareExtensionsButKeepPerAccountKeys() throws {
        try write([
            "enabledPlugins": ["p@m": true],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
            "permissions": ["allow": ["mcp__pencil"]],
            "theme": "dark",
            "statusLine": ["type": "command", "command": "primary"],
        ], to: settings(primary))
        try write(["statusLine": ["type": "command", "command": "work"], "theme": "light"], to: settings(work))
        try sync()
        let workSettings = try read(settings(work))
        #expect((workSettings["statusLine"] as? [String: Any])?["command"] as? String == "work")
        #expect(workSettings["theme"] as? String == "light")
        #expect((workSettings["enabledPlugins"] as? [String: Any])?["p@m"] as? Bool == true)
        #expect(((workSettings["permissions"] as? [String: Any])?["allow"] as? [String]) == ["mcp__pencil"])
        #expect(((workSettings["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 1)
        #expect(try read(settings(fresh))["theme"] == nil)
        // Idempotent: a second run changes nothing.
        #expect(try sync().changes.isEmpty)
    }

    @Test func skillsAreLinkedAndLocalOnesAdopted() throws {
        let fm = FileManager.default
        try temp.write("# a", to: "home/.claude/skills/alpha/SKILL.md")
        try temp.write("# org", to: "home/.claude/skills/synced/bucket/SKILL.md")
        try temp.write("# b", to: "home/.claude-work/skills/beta/SKILL.md")
        try fm.createSymbolicLink(atPath: home.appendingPathComponent(".claude/skills/broken").path, withDestinationPath: "/nonexistent/skill")
        try sync()
        for profile in [work, fresh] {
            let skills = profile.configURL.appendingPathComponent("skills")
            #expect(try fm.destinationOfSymbolicLink(atPath: skills.appendingPathComponent("alpha").path).hasSuffix(".claude/skills/alpha"))
            #expect(try fm.destinationOfSymbolicLink(atPath: skills.appendingPathComponent("beta").path).hasSuffix(".claude/skills/beta"))
            #expect(!fm.fileExists(atPath: skills.appendingPathComponent("synced").path))
            #expect((try? fm.destinationOfSymbolicLink(atPath: skills.appendingPathComponent("broken").path)) == nil)
        }
        #expect(readText(home.appendingPathComponent(".claude/skills/beta/SKILL.md")) == "# b")
        // Removing a skill from the primary removes its links.
        try fm.removeItem(at: home.appendingPathComponent(".claude/skills/alpha"))
        try sync()
        #expect((try? fm.attributesOfItem(atPath: work.configURL.appendingPathComponent("skills/alpha").path)) == nil)
    }

    @Test func invalidJSONStopsWithoutWriting() throws {
        try write(["mcpServers": ["a": ["command": "a"]]], to: globalConfig(primary))
        try temp.write("{ not json", to: "home/.claude-work/.claude.json")
        #expect(throws: (any Error).self) { try sync() }
        #expect(readText(globalConfig(work)) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: globalConfig(fresh).path))
    }

    @Test func changedFilesAreBackedUp() throws {
        try write(["mcpServers": ["a": ["command": "a"]]], to: globalConfig(primary))
        try write(["numStartups": 1], to: globalConfig(work))
        try sync()
        let runs = try FileManager.default.contentsOfDirectory(atPath: temp.paths.pool.sharedSyncBackups.path)
        #expect(runs.count == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: temp.paths.pool.sharedSyncBackups.appendingPathComponent(runs[0]).path)
        #expect(files.contains { $0.hasSuffix(".claude-work_.claude.json") })
    }
}
