import CryptoKit
import Foundation
import Testing
@testable import ClaudePool

@Suite struct UpdateServiceTests {
    static let bundleID = "test.claudepool.update"

    /// A fake `curl` that copies `download` to the `-o` path, or prints `reply` without one.
    private func fakeCurl(in temp: TempDirectory, reply: String = "", download: URL? = nil, exitCode: Int = 0, stderr: String = "") throws -> URL {
        let script = """
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          [ "$1" = "-o" ] && { out=$2; shift; }
          shift
        done
        if [ -n "$out" ]; then cp \(ShellQuote.quote(download?.path ?? "/dev/null")) "$out"; else printf '%s' \(ShellQuote.quote(reply)); fi
        printf '%s' \(ShellQuote.quote(stderr)) >&2
        exit \(exitCode)

        """
        let url = try temp.write(script, to: "bin/curl")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func service(_ temp: TempDirectory, curl: URL) -> UpdateService {
        var service = UpdateService(home: temp.url, workDirectory: temp.file("work"))
        service.curl = curl
        return service
    }

    /// An ad-hoc signed ClaudePool.app in a compressed disk image, like a release.
    private func diskImage(in temp: TempDirectory, version: String) throws -> (image: URL, sha256: String) {
        let root = temp.file("image-root")
        let app = root.appendingPathComponent(UpdateService.appName)
        let plist: [String: Any] = [
            "CFBundleIdentifier": Self.bundleID, "CFBundleShortVersionString": version,
            "CFBundleExecutable": "ClaudePool", "CFBundlePackageType": "APPL",
        ]
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = try temp.write("#!/bin/sh\nexit 0\n", to: "image-root/\(UpdateService.appName)/Contents/MacOS/ClaudePool")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(try runProcess(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path], environment: [:]).status == 0)
        let image = temp.file("ClaudePool-\(version).dmg")
        let created = try runProcess(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                     ["create", "-quiet", "-volname", "Claude Pool", "-srcfolder", root.path, "-format", "UDZO", image.path],
                                     environment: [:])
        #expect(created.status == 0)
        let hash = SHA256.hash(data: try Data(contentsOf: image)).map { String(format: "%02x", $0) }.joined()
        return (image, hash)
    }

    private func release(_ version: String, sha256: String?) -> AppRelease {
        AppRelease(version: AppVersion(version)!, pageURL: URL(string: "https://github.com/x/y/releases/tag/v\(version)")!,
                   diskImageURL: URL(string: "https://github.com/x/y/releases/download/v\(version)/ClaudePool-\(version).dmg")!,
                   sha256: sha256)
    }

    // MARK: Versions

    @Test func versionsCompareNumerically() throws {
        #expect(AppVersion("v1.6.0")?.parts == [1, 6, 0])
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        #expect(AppVersion("1.6")! == AppVersion("1.6.0")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99")!)
        #expect(!(AppVersion("1.6.0")! > AppVersion("1.6.0")!))
        for bad in ["", "v", "1.x", "1..2", "1.6.0-beta", "-1.0", "１.2"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    // MARK: Release replies

    @Test func releaseTakesTheDiskImageAndItsChecksum() throws {
        let hex = String(repeating: "ab", count: 32)
        let json = """
        {"tag_name":"v1.7.0","html_url":"https://github.com/x/y/releases/tag/v1.7.0","body":"notes",
         "assets":[{"name":"notes.txt","browser_download_url":"https://e/notes.txt","digest":"sha256:\(String(repeating: "00", count: 32))"},
                   {"name":"ClaudePool-1.7.0.dmg","browser_download_url":"https://e/ClaudePool-1.7.0.dmg","digest":"sha256:\(hex.uppercased())"}]}
        """
        let release = try #require(UpdateService.release(from: Data(json.utf8)))
        #expect(release.version == AppVersion("1.7.0"))
        #expect(release.pageURL.absoluteString == "https://github.com/x/y/releases/tag/v1.7.0")
        #expect(release.diskImageURL?.absoluteString == "https://e/ClaudePool-1.7.0.dmg")
        #expect(release.sha256 == hex)
    }

    @Test func releaseWithoutUsableChecksumHasNone() throws {
        for digest in [nil, "md5:abc", "sha256:short", "sha256:\(String(repeating: "zz", count: 32))"] as [String?] {
            let field = digest.map { #","digest":"\#($0)""# } ?? ""
            let json = #"{"tag_name":"v1.7.0","html_url":"https://e/r","assets":[{"name":"a.dmg","browser_download_url":"https://e/a.dmg"\#(field)}]}"#
            #expect(UpdateService.release(from: Data(json.utf8))?.sha256 == nil)
        }
        #expect(UpdateService.release(from: Data(#"{"tag_name":"nightly","html_url":"https://e/r"}"#.utf8)) == nil)
        #expect(UpdateService.release(from: Data("not json".utf8)) == nil)
    }

    @Test func latestReleaseComesFromCurl() async throws {
        let temp = try TempDirectory()
        let curl = try fakeCurl(in: temp, reply: #"{"tag_name":"v2.0.0","html_url":"https://e/r","assets":[]}"#)
        let release = try await service(temp, curl: curl).latestRelease()
        #expect(release.version == AppVersion("2.0.0"))
        #expect(release.diskImageURL == nil)
    }

    @Test func curlErrorsAreReported() async throws {
        let temp = try TempDirectory()
        let curl = try fakeCurl(in: temp, exitCode: 22, stderr: "curl: (22) The requested URL returned error: 404\n")
        await #expect(throws: UpdateError.checkFailed("The requested URL returned error: 404")) {
            try await service(temp, curl: curl).latestRelease()
        }
    }

    // MARK: Download and verification

    @Test func downloadVerifiesAndStagesTheApp() async throws {
        let temp = try TempDirectory()
        let (image, hash) = try diskImage(in: temp, version: "9.9.9")
        let updater = service(temp, curl: try fakeCurl(in: temp, download: image))
        let staged = try await updater.download(release("9.9.9", sha256: hash), bundleIdentifier: Self.bundleID)
        #expect(staged.lastPathComponent == UpdateService.appName)
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        #expect(info?["CFBundleShortVersionString"] as? String == "9.9.9")
        // The image is detached and deleted once the app is copied out.
        #expect(!FileManager.default.fileExists(atPath: temp.file("work/mount/\(UpdateService.appName)").path))
        #expect(!FileManager.default.fileExists(atPath: temp.file("work/ClaudePool-9.9.9.dmg").path))
    }

    @Test func downloadRejectsWrongChecksumAppOrVersion() async throws {
        let temp = try TempDirectory()
        let (image, hash) = try diskImage(in: temp, version: "9.9.9")
        let updater = service(temp, curl: try fakeCurl(in: temp, download: image))
        await #expect(throws: UpdateError.checksumMismatch) {
            try await updater.download(release("9.9.9", sha256: String(repeating: "0", count: 64)), bundleIdentifier: Self.bundleID)
        }
        await #expect(throws: UpdateError.invalidApp("it isn't Claude Pool (different bundle identifier).")) {
            try await updater.download(release("9.9.9", sha256: hash), bundleIdentifier: "com.example.other")
        }
        await #expect(throws: UpdateError.invalidApp("its version doesn't match release 9.9.10.")) {
            try await updater.download(release("9.9.10", sha256: hash), bundleIdentifier: Self.bundleID)
        }
        await #expect(throws: UpdateError.noDiskImage) {
            try await updater.download(release("9.9.9", sha256: nil), bundleIdentifier: Self.bundleID)
        }
    }

    @Test func verifyRejectsATamperedApp() async throws {
        let temp = try TempDirectory()
        _ = try diskImage(in: temp, version: "9.9.9")
        let app = temp.file("image-root/\(UpdateService.appName)")
        try temp.write("#!/bin/sh\necho changed\n", to: "image-root/\(UpdateService.appName)/Contents/MacOS/ClaudePool")
        await #expect(throws: UpdateError.invalidApp("its code signature is invalid.")) {
            try await service(temp, curl: URL(fileURLWithPath: "/usr/bin/false")).verify(app, bundleIdentifier: Self.bundleID, version: AppVersion("9.9.9")!)
        }
    }

    // MARK: Install

    @Test func installScriptSwapsBundlesAfterTheAppQuits() throws {
        let temp = try TempDirectory()
        let dest = temp.file("Applications/ClaudePool.app")
        let incoming = temp.file("Applications/.ClaudePool-update.app")
        try temp.write("old", to: "Applications/ClaudePool.app/marker")
        try temp.write("new", to: "Applications/.ClaudePool-update.app/marker")
        let opener = try temp.write("#!/bin/sh\nprintf '%s' \"$1\" > \"$(dirname \"$0\")/opened\"\n", to: "bin/open")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let script = try temp.write(UpdateService.installScript, to: "install.sh")

        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["0.5"]
        try app.run()
        let result = try runProcess(URL(fileURLWithPath: "/bin/sh"),
                                    [script.path, String(app.processIdentifier), incoming.path, dest.path, opener.path],
                                    environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.status == 0)
        #expect(!app.isRunning)
        #expect(readText(dest.appendingPathComponent("marker")) == "new")
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        #expect(!FileManager.default.fileExists(atPath: incoming.path + ".old"))
        #expect(readText(temp.file("bin/opened")) == dest.path)
    }

    @Test func installRefusesCopiesItCannotReplace() async throws {
        let temp = try TempDirectory()
        let updater = service(temp, curl: URL(fileURLWithPath: "/usr/bin/false"))
        let staged = temp.file("work/ClaudePool.app")
        await #expect(throws: UpdateError.cannotInstall("Claude Pool isn't running from an app bundle.")) {
            try await updater.install(staged, over: temp.file("build/debug/ClaudePool"), waitingFor: 1)
        }
        await #expect(throws: UpdateError.cannotInstall("Claude Pool is running from the disk image. Move it to Applications first.")) {
            try await updater.install(staged, over: URL(fileURLWithPath: "/Volumes/Claude Pool/ClaudePool.app"), waitingFor: 1)
        }
    }

    @Test func detachedProcessRuns() async throws {
        let temp = try TempDirectory()
        let marker = temp.file("ran")
        try UpdateService.spawnDetached(["/bin/sh", "-c", "echo ok > \(ShellQuote.quote(marker.path))"])
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(readText(marker) == "ok\n")
    }

    @Test func settingDefaultsToOnAndRoundTrips() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultWorkingDirectory":"~"}"#.utf8))
        #expect(old.updateAutomatically)
        var settings = AppSettings()
        settings.updateAutomatically = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.updateAutomatically)
    }
}
