import Foundation
import Testing
@testable import ClaudePool

@Suite struct CommandLineArgumentsTests {
    @Test func noArgumentsShowsHelp() throws {
        #expect(try CommandLineArguments.parse([]) == .help(nil))
        #expect(try CommandLineArguments.parse(["--help"]) == .help(nil))
        #expect(try CommandLineArguments.parse(["help", "open"]) == .help("open"))
        #expect(try CommandLineArguments.parse(["status", "--help"]) == .help("status"))
        #expect(try CommandLineArguments.parse(["open", "work", "-h"]) == .help("open"))
    }

    @Test func accountNameIsShortForOpen() throws {
        #expect(try CommandLineArguments.parse(["work"]) == .open(OpenRequest(account: "work", shorthand: true)))
    }

    @Test func openTakesFolderPlaceAndClaudeOptions() throws {
        #expect(try CommandLineArguments.parse(["open", "work", "api", "-c"])
            == .open(OpenRequest(account: "work", folder: "api", claudeArguments: ["-c"])))
        #expect(try CommandLineArguments.parse(["work", "--herdr", "--", "fix it", "--model", "opus"])
            == .open(OpenRequest(account: "work", place: .new(.herdr), claudeArguments: ["fix it", "--model", "opus"], shorthand: true)))
        #expect(try CommandLineArguments.parse(["open", "-t"]) == .open(OpenRequest(place: .new(.terminal))))
        #expect(try CommandLineArguments.parse(["open", "--new", "work"]) == .open(OpenRequest(account: "work", place: .new(nil))))
        // Options after the first unknown one belong to claude, even claude-pool's own names.
        #expect(try CommandLineArguments.parse(["open", "work", "--resume", "-t"])
            == .open(OpenRequest(account: "work", claudeArguments: ["--resume", "-t"])))
    }

    @Test func openRejectsAThirdWord() {
        #expect(throws: CLIError.self) { try CommandLineArguments.parse(["open", "work", "api", "fix it"]) }
    }

    @Test func commandsAndAliases() throws {
        #expect(try CommandLineArguments.parse(["ls", "--json"]) == .list(json: true))
        #expect(try CommandLineArguments.parse(["switch", "work"]) == .use("work"))
        #expect(try CommandLineArguments.parse(["rm", "work", "-y", "--trash"]) == .remove("work", trash: true, confirmed: true))
        #expect(try CommandLineArguments.parse(["login", "work", "--sso"]) == .login("work", arguments: ["--sso"]))
        #expect(try CommandLineArguments.parse(["usage", "--check"]) == .usage(nil, check: true))
        #expect(try CommandLineArguments.parse(["rename", "work", "Job", "--slug=job"]) == .rename("work", to: "Job", slug: "job"))
        #expect(try CommandLineArguments.parse(["add", "My Work", "--email=a@b.c", "--no-track", "--dir", "~/x", "--use"])
            == .add(AddRequest(name: "My Work", email: "a@b.c", directory: "~/x", trackUsage: false, makeActive: true)))
    }

    @Test func mistakesAreUsageErrors() {
        for arguments in [["use"], ["list", "extra"], ["--bogus"], ["add", "x", "--email"], ["remove", "x", "--force"], ["login"]] {
            #expect(throws: CLIError.self) { try CommandLineArguments.parse(arguments) }
            #expect((try? CommandLineArguments.parse(arguments)) == nil)
        }
        do {
            _ = try CommandLineArguments.parse(["use"])
        } catch let error as CLIError {
            #expect(error.exitCode == 2)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite struct AccountQueryTests {
    let profiles: [Profile] = {
        var work = Profile.makeDefault(home: URL(fileURLWithPath: "/Users/x"))
        work.name = "akun1"
        let make = { (name: String, slug: String, index: Int) in
            Profile(id: UUID(), name: name, slug: slug, configDir: "/Users/x/.claude-\(slug)", colorHex: "#0A84FF",
                    isDefault: false, trackingEnabled: false, originalStatusLine: nil, sortIndex: index, createdAt: Date())
        }
        return [work, make("akun2", "akun2", 1), make("Personal Max", "personal", 2)]
    }()

    @Test func matchesSlugNameNumberAndPrefix() throws {
        #expect(try AccountQuery.resolve("default", in: profiles).name == "akun1")
        #expect(try AccountQuery.resolve("AKUN1", in: profiles).isDefault)
        #expect(try AccountQuery.resolve("2", in: profiles).name == "akun2")
        #expect(try AccountQuery.resolve("personal max", in: profiles).slug == "personal")
        #expect(try AccountQuery.resolve("pers", in: profiles).slug == "personal")
    }

    @Test func reportsAmbiguousAndUnknown() {
        #expect(throws: AccountQueryError.ambiguous("akun", matches: ["akun1", "akun2"])) { try AccountQuery.resolve("akun", in: profiles) }
        #expect(throws: AccountQueryError.notFound("work", accounts: ["akun1", "akun2", "Personal Max"])) { try AccountQuery.resolve("work", in: profiles) }
        #expect(throws: AccountQueryError.self) { try AccountQuery.resolve("9", in: profiles) }
    }
}

@MainActor
@Suite struct CommandLineToolTests {
    let temp: TempDirectory
    let store: ProfileStore
    let fakeClaude: URL

    init() throws {
        temp = try TempDirectory()
        store = ProfileStore(paths: temp.paths)
        store.load()
        fakeClaude = try temp.write("#!/bin/sh\nexit 0\n", to: "bin/claude")
        chmod(fakeClaude.path, 0o755)
    }

    /// Everything the tool printed, and what it would have run.
    final class Recorder {
        var output = ""
        var errors = ""
        var execs: [ProgramRun] = []
        var attached: [ProgramRun] = []
        var notifications = 0
        var answers: [String] = []
    }

    private func tool(interactive: Bool = false, _ recorder: Recorder) throws -> CommandLineTool {
        let executable = try collectorBinary().deletingLastPathComponent().appendingPathComponent("ClaudePool")
        let tool = CommandLineTool(paths: temp.paths, executable: executable,
                                   environment: ["PATH": fakeClaude.deletingLastPathComponent().path, "HOME": temp.paths.userHome.path],
                                   currentDirectory: temp.url.path)
        tool.interactive = interactive
        tool.write = { recorder.output += $0 }
        tool.writeError = { recorder.errors += $0 }
        tool.readAnswer = { recorder.answers.isEmpty ? nil : recorder.answers.removeFirst() }
        tool.exec = { recorder.execs.append($0); return 0 }
        tool.runAttached = { recorder.attached.append($0); return 0 }
        tool.notifyApp = { recorder.notifications += 1 }
        return tool
    }

    private func dir(_ name: String) -> String {
        temp.paths.userHome.appendingPathComponent(name).path
    }

    private func reloaded() -> ProfileStore {
        let fresh = ProfileStore(paths: temp.paths)
        fresh.load()
        return fresh
    }

    @Test func listsAccountsAndMarksTheActiveOne() async throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        store.setActive(work.id)
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["list"]) == 0)
        let lines = recorder.output.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[1].contains("Default") && !lines[1].hasPrefix("*"))
        #expect(lines[2].hasPrefix("*") && lines[2].contains("Work") && lines[2].contains("work"))
    }

    @Test func listPrintsJSON() async throws {
        try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["list", "--json"]) == 0)
        let decoded = try JSONSerialization.jsonObject(with: Data(recorder.output.utf8)) as? [[String: Any]]
        #expect(decoded?.map { $0["slug"] as? String } == ["default", "work"])
        #expect(decoded?.first?["active"] as? Bool == true)
    }

    @Test func openRunsClaudeHereWithTheProfileDirectory() async throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["work", "-c"]) == 0)
        let run = try #require(recorder.execs.first)
        #expect(run.path == fakeClaude.path)
        #expect(run.arguments == ["claude", "-c"])
        #expect(run.environment["CLAUDE_CONFIG_DIR"] == work.configDir)
        #expect(run.directory == nil)
    }

    @Test func openDefaultUnsetsTheVariable() async throws {
        let recorder = Recorder()
        let subject = try tool(recorder)
        subject.environment["CLAUDE_CONFIG_DIR"] = "/somewhere/else"
        #expect(await subject.run(["open", "default"]) == 0)
        #expect(recorder.execs.first?.environment["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func openFindsAProjectByTheStartOfItsName() async throws {
        let projects = temp.paths.userHome.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("mokanata"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("api"), withIntermediateDirectories: true)
        var settings = AppSettings()
        settings.projectsFolder = "~/projects"
        try AtomicFile.ensureDirectory(temp.paths.appSupport, permissions: 0o700)
        try ProfileStore.encoder.encode(settings).write(to: temp.paths.appSettingsFile)

        let recorder = Recorder()
        #expect(try await tool(recorder).run(["open", "default", "moka"]) == 0)
        #expect(recorder.execs.first?.directory == projects.appendingPathComponent("mokanata").path)

        let missing = Recorder()
        #expect(try await tool(missing).run(["open", "default", "nothing"]) == 1)
        #expect(missing.errors.contains("No folder “nothing” here or in ~/projects."))
        #expect(missing.execs.isEmpty)
    }

    @Test func unknownWordIsReportedAsCommandOrAccount() async throws {
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["lst"]) == 2)
        #expect(recorder.errors.contains("neither a command nor an account"))
    }

    @Test func useSwitchesTheActiveProfileAndTellsTheApp() async throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["use", "Work"]) == 0)
        #expect(try store.pointer.read() == work.configDir)
        #expect(recorder.notifications == 1)

        let current = Recorder()
        #expect(try await tool(current).run(["current"]) == 0)
        #expect(current.output == "Work\n")
    }

    @Test func addCreatesTheProfileAndItsFolder() async throws {
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["add", "Side Project", "--no-track", "--no-login", "--color", "green"]) == 0)
        let added = try #require(reloaded().profiles.first { $0.slug == "side-project" })
        #expect(added.configDir == dir(".claude-side-project"))
        #expect(added.colorHex == "#30D158")
        #expect(FileManager.default.fileExists(atPath: added.configDir))
        #expect(recorder.notifications == 1)
        #expect(recorder.attached.isEmpty)
    }

    @Test func addTurnsOnTrackingAndSignsIn() async throws {
        let recorder = Recorder()
        #expect(try await tool(interactive: true, recorder).run(["add", "Work", "--email", "me@example.com", "--use"]) == 0)
        let added = try #require(reloaded().profiles.first { $0.slug == "work" })
        #expect(added.trackingEnabled)
        let login = try #require(recorder.attached.first)
        #expect(login.arguments == ["claude", "auth", "login", "--email", "me@example.com"])
        #expect(login.environment["CLAUDE_CONFIG_DIR"] == added.configDir)
        #expect(try store.pointer.read() == added.configDir)
    }

    @Test func addRejectsADuplicateName() async throws {
        try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["add", "work", "--slug", "work-2", "--no-login"]) == 1)
        #expect(recorder.errors.contains("Another profile already uses this name."))
    }

    @Test func renameKeepsTheFolder() async throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        #expect(try await tool(Recorder()).run(["rename", "work", "Job", "--slug", "job"]) == 0)
        let renamed = try #require(reloaded().profile(id: work.id))
        #expect(renamed.name == "Job")
        #expect(renamed.slug == "job")
        #expect(renamed.configDir == work.configDir)
    }

    @Test func removeAsksFirst() async throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))

        let unattended = Recorder()
        #expect(try await tool(unattended).run(["remove", "work"]) == 2)
        #expect(reloaded().profile(id: work.id) != nil)

        let declined = Recorder()
        declined.answers = ["n"]
        #expect(try await tool(interactive: true, declined).run(["remove", "work"]) == 1)
        #expect(reloaded().profile(id: work.id) != nil)

        let accepted = Recorder()
        accepted.answers = ["y"]
        #expect(try await tool(interactive: true, accepted).run(["remove", "work"]) == 0)
        #expect(reloaded().profile(id: work.id) == nil)
        #expect(FileManager.default.fileExists(atPath: work.configDir))
        #expect(accepted.notifications == 1)
    }

    @Test func removeNeverTakesDefault() async throws {
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["remove", "default", "--yes"]) == 1)
        #expect(reloaded().defaultProfile != nil)
    }

    @Test func envPinsTheShell() async throws {
        try store.add(name: "Work", slug: "work", configDir: dir("it's work"))
        let work = Recorder()
        #expect(try await tool(work).run(["env", "work"]) == 0)
        #expect(work.output == "export CLAUDE_CONFIG_DIR='\(dir("it"))'\\''s work'\n")

        let standard = Recorder()
        #expect(try await tool(standard).run(["env", "default"]) == 0)
        #expect(standard.output.hasPrefix("unset CLAUDE_CONFIG_DIR\n"))
    }

    @Test func loginAndLogoutRunClaudeAuth() async throws {
        let work = try store.add(name: "Work", slug: "work", configDir: dir(".claude-work"))
        let recorder = Recorder()
        #expect(try await tool(recorder).run(["login", "work", "--sso"]) == 0)
        #expect(try await tool(recorder).run(["logout", "work"]) == 0)
        #expect(recorder.attached.map(\.arguments) == [["claude", "auth", "login", "--sso"], ["claude", "auth", "logout"]])
        #expect(recorder.attached.allSatisfy { $0.environment["CLAUDE_CONFIG_DIR"] == work.configDir })
        #expect(recorder.notifications == 2)
    }

    @Test func recognisesItsCommandName() {
        #expect(CommandLineTool.isInvoked(as: "/usr/local/bin/claude-pool"))
        #expect(CommandLineTool.isInvoked(as: "claude-pool"))
        #expect(!CommandLineTool.isInvoked(as: "/Applications/ClaudePool.app/Contents/MacOS/ClaudePool"))
        #expect(!CommandLineTool.isInvoked(as: nil))
    }
}

@Suite struct CommandLineInstallerTests {
    let temp: TempDirectory
    let executable: URL
    let user: URL
    let system: URL

    init() throws {
        temp = try TempDirectory()
        executable = try temp.write("app", to: "Apps/ClaudePool.app/Contents/MacOS/ClaudePool")
        user = temp.url.appendingPathComponent("user-bin", isDirectory: true)
        system = temp.url.appendingPathComponent("system-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    }

    private func installer(_ executable: URL? = nil) -> CommandLineInstaller {
        var installer = CommandLineInstaller(home: temp.url, executable: executable ?? self.executable, loginShell: "/bin/zsh")
        installer.folders = [user, system]
        return installer
    }

    @Test func linksInAFolderOnThePath() async throws {
        let link = try await installer().install(searchPath: [user.path])
        #expect(link == user.appendingPathComponent("claude-pool"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == executable.path)
        #expect(installer().state() == .installed(link.path))
    }

    @Test func fallsBackToTheLastFolder() async throws {
        let link = try await installer().install(searchPath: [])
        #expect(link == system.appendingPathComponent("claude-pool"))
    }

    @Test func repointsALinkToAnotherCopy() async throws {
        let old = try temp.write("old", to: "Old/ClaudePool.app/Contents/MacOS/ClaudePool")
        try FileManager.default.createSymbolicLink(atPath: system.appendingPathComponent("claude-pool").path, withDestinationPath: old.path)
        #expect(installer().state() == .otherCopy(system.appendingPathComponent("claude-pool").path))
        let link = try await installer().install(searchPath: [user.path])
        #expect(link == system.appendingPathComponent("claude-pool"))
        #expect(installer().state() == .installed(link.path))
    }

    @Test func neverReplacesSomeoneElsesFile() async throws {
        let foreign = try temp.write("#!/bin/sh\n", to: "user-bin/claude-pool")
        await #expect(throws: CommandLineInstallError.occupied(foreign.path)) {
            try await installer().install(searchPath: [user.path])
        }
        #expect(readText(foreign) == "#!/bin/sh\n")
    }

    @Test func uninstallRemovesOnlyClaudePoolLinks() async throws {
        let link = try await installer().install(searchPath: [user.path])
        let other = system.appendingPathComponent("claude-pool")
        try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: "/usr/bin/true")
        try await installer().uninstall()
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: other.path) == "/usr/bin/true")
        #expect(installer().state() == .notInstalled)
    }
}
