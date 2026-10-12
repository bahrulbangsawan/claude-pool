import Foundation
import Testing
@testable import ClaudePool

@Suite struct PointerFileServiceTests {
    let temp: TempDirectory
    let service: PointerFileService

    init() throws {
        temp = try TempDirectory()
        service = PointerFileService(pool: temp.paths.pool)
    }

    @Test func missingFileMeansDefault() throws {
        #expect(try service.read() == nil)
    }

    @Test func writesDirectoryWithoutTrailingNewline() throws {
        try service.write("/Users/x/.claude-work")
        let data = try Data(contentsOf: service.url)
        #expect(data == Data("/Users/x/.claude-work".utf8))
        #expect(try service.read() == "/Users/x/.claude-work")
    }

    @Test func emptyFileMeansDefault() throws {
        try service.write("/Users/x/.claude-work")
        try service.write(nil)
        #expect(try Data(contentsOf: service.url).isEmpty)
        #expect(try service.read() == nil)
    }

    @Test func permissionsAre0600AndHomeIs0700() throws {
        try service.write("/a")
        #expect(permissions(of: service.url) == 0o600)
        #expect(permissions(of: temp.paths.pool.home) == 0o700)
    }

    @Test func atomicWriteLeavesNoTempFiles() throws {
        for index in 0..<20 { try service.write("/dir/\(index)") }
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.paths.pool.home.path)
        #expect(names == ["active"])
        #expect(try service.read() == "/dir/19")
    }

    @Test func toleratesHandEditedTrailingNewline() throws {
        try temp.write("/Users/x/.claude-work\n", to: "home/.claude-pool/active")
        #expect(try service.read() == "/Users/x/.claude-work")
    }

    @Test func setActiveUsesProfileEnvironmentValue() throws {
        let defaultProfile = Profile.makeDefault(home: temp.paths.userHome)
        var work = defaultProfile
        work.isDefault = false
        work.configDir = "/Users/x/.claude-work"
        try service.setActive(work)
        #expect(try service.read() == "/Users/x/.claude-work")
        try service.setActive(defaultProfile)
        #expect(try service.read() == nil)
    }
}
