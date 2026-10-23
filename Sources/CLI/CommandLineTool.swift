import AppKit
import Foundation

/// `claude-pool`: Claude Pool's accounts from any terminal or herdr pane.
///
/// It is the app's own executable started under another name, through the link that Settings ›
/// Command Line Tool installs, so it reads and writes the same profiles, pointer file and launcher
/// scripts as the app. After a change it tells the running app, which reloads its profiles.
@MainActor
final class CommandLineTool {
    nonisolated static let commandName = "claude-pool"
    /// Posted after the tool changed profiles, a sign-in or the active profile.
    nonisolated static let profilesChanged = Notification.Name("ClaudePool.profilesChanged")

    let model: AppModel
    /// The app executable this command runs from, with links resolved.
    let executable: URL?
    var environment: [String: String]
    var currentDirectory: String
    /// stdin and stdout are a terminal: questions, sign-in and hints need one.
    var interactive = false
    var colors = false
    var write: (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
    var writeError: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    var readAnswer: () -> String? = { readLine() }
    /// Replaces this process with the program; returns only if that failed (errno).
    var exec: (ProgramRun) -> Int32 = ForegroundProcess.exec
    /// Runs a program in this terminal and returns its exit status.
    var runAttached: (ProgramRun) -> Int32 = ForegroundProcess.run
    var notifyApp: () -> Void = {
        DistributedNotificationCenter.default().postNotificationName(CommandLineTool.profilesChanged, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Read once at start; the tool never writes app settings.
    private(set) var settings = AppSettings()

    var paths: Paths { model.paths }
    var profiles: [Profile] { model.profiles }

    init(paths: Paths, executable: URL?, environment: [String: String], currentDirectory: String) {
        self.executable = executable
        self.environment = environment
        self.currentDirectory = currentDirectory
        model = AppModel(paths: paths, bundledHelper: Self.collector(beside: executable))
        model.liveChecksEnabled = false
    }

    /// Whether the executable was started as `claude-pool` rather than as the app.
    static func isInvoked(as name: String?) -> Bool {
        name.map { URL(fileURLWithPath: $0).lastPathComponent == commandName } ?? false
    }

    static func live() -> CommandLineTool {
        let environment = ProcessInfo.processInfo.environment
        let tool = CommandLineTool(
            paths: .live(),
            // Bundle.main sees the link, not the app it points into.
            executable: Bundle.main.executableURL?.resolvingSymlinksInPath(),
            environment: environment,
            currentDirectory: FileManager.default.currentDirectoryPath
        )
        tool.interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        tool.colors = isatty(STDOUT_FILENO) == 1 && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
        return tool
    }

    /// The collector shipped with this executable: in the app's Helpers, or beside a SwiftPM build.
    static func collector(beside executable: URL?) -> URL {
        guard let executable else { return CollectorInstaller.bundledHelperURL() }
        let folder = executable.deletingLastPathComponent()
        let inBundle = folder.deletingLastPathComponent().appendingPathComponent("Helpers/\(PoolPaths.collectorName)")
        return FileManager.default.fileExists(atPath: inBundle.path) ? inBundle : folder.appendingPathComponent(PoolPaths.collectorName)
    }

    /// ClaudePool.app, when this executable is inside one.
    var appBundleURL: URL? {
        guard let app = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
              app.pathExtension == "app" else { return nil }
        return app
    }

    // MARK: Running

    func run(_ arguments: [String]) async -> Int32 {
        do {
            let command = try CommandLineArguments.parse(arguments)
            load()
            return try await perform(command)
        } catch let error as CLIError {
            writeError("claude-pool: \(error.message)\n")
            return error.exitCode
        } catch {
            writeError("claude-pool: \(error.localizedDescription)\n")
            return 1
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: paths.appSettingsFile),
           let decoded = try? ProfileStore.decoder.decode(AppSettings.self, from: data) {
            settings = decoded
        }
        model.profileStore.load()
        model.usageStore.reload()
        model.authStore.reloadDetails(profiles)
        if let error = model.profileStore.lastError { warn(error) }
    }

    private func perform(_ command: CLICommand) async throws -> Int32 {
        switch command {
        case let .help(topic): return try help(topic)
        case .version: return version()
        case let .list(json): return try list(json: json)
        case .current: return try current()
        case let .open(request): return try await open(request)
        case let .use(query): return try use(query)
        case let .add(request): return try add(request)
        case let .login(query, arguments): return try signIn(try account(query), arguments: arguments)
        case let .logout(query): return try logout(query)
        case let .status(query): return try await status(query)
        case let .usage(query, check): return try await usage(query, check: check)
        case let .rename(query, name, slug): return try rename(query, to: name, slug: slug)
        case let .remove(query, trash, confirmed): return try remove(query, trash: trash, confirmed: confirmed)
        case let .env(query): return try env(query)
        case .projects: return try projects()
        case .sessions: return sessions()
        }
    }

    // MARK: Commands

    private func help(_ topic: String?) throws -> Int32 {
        guard let topic else {
            write(Help.overview)
            return 0
        }
        guard let text = Help.text(for: topic) else { throw CLIError.usage("No command \(topic). Run claude-pool help.") }
        write(text)
        return 0
    }

    private func version() -> Int32 {
        let version = appBundleURL.flatMap(Bundle.init(url:))?.infoDictionary?["CFBundleShortVersionString"] as? String
        write("claude-pool \(version ?? "(development build)")\n")
        if interactive, let app = appBundleURL ?? executable { write(paint("from \(paths.abbreviate(app.path))\n", .dim)) }
        return 0
    }

    private func list(json: Bool) throws -> Int32 {
        let activeID = model.profileStore.activeProfileID
        if json {
            let summaries = profiles.enumerated().map { index, profile in
                let details = model.authStore.details[profile.id]
                let window = { (kind: UsageWindowKind) in
                    self.model.usageState(profile, kind).displayedWindow.map { AccountSummary.Window(usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }
                }
                return AccountSummary(
                    number: index + 1, name: profile.name, slug: profile.slug, active: profile.id == activeID,
                    isDefault: profile.isDefault, directory: profile.configDir, email: details?.emailAddress,
                    plan: plan(details), usageTracking: profile.trackingEnabled,
                    fiveHour: window(.fiveHour), sevenDay: window(.sevenDay)
                )
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            write(String(decoding: try encoder.encode(summaries), as: UTF8.self) + "\n")
            return 0
        }
        let rows = profiles.enumerated().map { index, profile -> [Cell] in
            let details = model.authStore.details[profile.id]
            return [
                profile.id == activeID ? Cell("*", .green) : Cell(""),
                Cell("\(index + 1)", .dim),
                Cell(profile.name, profile.id == activeID ? .bold : nil),
                Cell(profile.slug, .dim),
                details?.emailAddress.map { Cell($0) } ?? Cell("not signed in", .dim),
                Cell(plan(details) ?? ""),
                usageCell(profile, .fiveHour),
                usageCell(profile, .sevenDay),
            ]
        }
        write(table(["", "#", "ACCOUNT", "SLUG", "SIGNED IN AS", "PLAN", "5H", "7D"], rows))
        if let unknown = model.profileStore.unknownActiveDirectory {
            warn("The active account is \(paths.abbreviate(unknown)), which isn't in Claude Pool.")
        }
        return 0
    }

    private func current() throws -> Int32 {
        write(try activeAccount().name + "\n")
        return 0
    }

    private func open(_ request: OpenRequest) async throws -> Int32 {
        let profile: Profile
        do {
            profile = try account(request.account)
        } catch AccountQueryError.notFound where request.shorthand {
            throw CLIError.usage("“\(request.account ?? "")” is neither a command nor an account. Run claude-pool help, or claude-pool list for accounts.")
        }
        let folder = try request.folder.map(resolveFolder)
        let binary = try claudeBinary()

        guard case let .new(chosenHost) = request.place else {
            if interactive {
                let who = model.authStore.details[profile.id]?.emailAddress.map { " · \($0)" } ?? ""
                writeError(paint("claude-pool: \(profile.name)\(who)\n", .dim))
            }
            let run = ProgramRun(path: binary.path, arguments: ["claude"] + request.claudeArguments,
                                 environment: claudeEnvironment(for: profile), directory: folder)
            let error = exec(run)
            guard error != 0 else { return 0 }
            throw CLIError(message: "Couldn't start \(binary.path): \(String(cString: strerror(error))).")
        }
        let host = chosenHost ?? settings.terminalHost
        let title = folder.map { "\(URL(fileURLWithPath: $0).lastPathComponent) · \(profile.name)" }
        try await model.launcher.launch(profile, workingDirectory: folder ?? currentDirectory, claudePath: binary.path,
                                        arguments: request.claudeArguments, title: title, in: host)
        say("Opened \(profile.name) in a new \(host == .herdr ? "herdr tab" : "Terminal window").")
        return 0
    }

    private func use(_ query: String) throws -> Int32 {
        let profile = try account(query)
        model.profileStore.setActive(profile.id)
        if let error = model.profileStore.lastError { throw CLIError(message: error) }
        notifyApp()
        say("\(profile.name) is now the active account.")
        if model.shell.status() == .installed {
            hint("A plain claude started from now on uses it. Running sessions keep their account.")
        } else {
            hint("A plain claude follows it once the shell integration is installed (Claude Pool › Settings › Shell Integration). claude-pool open \(profile.slug) works either way.")
        }
        return 0
    }

    private func add(_ request: AddRequest) throws -> Int32 {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = request.slug ?? Slug.make(from: name)
        let directory = request.directory.map(absolutePath) ?? paths.userHome.appendingPathComponent(".claude-\(slug)").path
        let color = try request.color.map(colorHex)
        let existed = FileManager.default.fileExists(atPath: directory)
        let profile = try model.profileStore.add(name: name, slug: slug, configDir: directory, colorHex: color)
        try? model.writeProfileDirectories()
        var tracking = false
        // Like Add Account in the app: a new folder has nothing to preserve, so tracking goes on
        // directly. An existing folder keeps its settings until the app's before/after confirmation.
        if request.trackUsage, !existed {
            do {
                try model.enableTracking(profile)
                tracking = true
            } catch {
                warn("Couldn't turn on usage tracking: \(error.localizedDescription) Turn it on in Claude Pool later.")
            }
        }
        notifyApp()
        say("Added \(profile.name) (\(paths.abbreviate(directory)))\(tracking ? " with usage tracking" : "").")
        if existed, request.trackUsage {
            hint("Its folder already existed, so usage tracking stays off until you turn it on in Claude Pool, which shows the change first.")
        }

        var status: Int32 = 0
        if request.signIn {
            if interactive {
                status = try signIn(profile, arguments: request.email.map { ["--email", $0] } ?? [])
            } else {
                hint("Sign it in from a terminal: claude-pool login \(profile.slug)")
            }
        }
        if request.makeActive {
            model.profileStore.setActive(profile.id)
            notifyApp()
            say("\(profile.name) is now the active account.")
        }
        if status == 0 { hint("Start claude with it: claude-pool open \(profile.slug)") }
        return status
    }

    /// Claude Code's own sign-in, in this terminal.
    private func signIn(_ profile: Profile, arguments: [String]) throws -> Int32 {
        let binary = try claudeBinary()
        let status = runAttached(ProgramRun(path: binary.path, arguments: ["claude", "auth", "login"] + arguments,
                                            environment: claudeEnvironment(for: profile)))
        notifyApp()
        if status == 0 {
            say("\(profile.name) is signed in.")
        } else {
            warn("Sign-in didn't finish. Try again with: claude-pool login \(profile.slug)")
        }
        return status
    }

    private func logout(_ query: String) throws -> Int32 {
        let profile = try account(query)
        let binary = try claudeBinary()
        let status = runAttached(ProgramRun(path: binary.path, arguments: ["claude", "auth", "logout"],
                                            environment: claudeEnvironment(for: profile)))
        notifyApp()
        return status
    }

    private func status(_ query: String?) async throws -> Int32 {
        let targets = try query.map { [try account($0)] } ?? profiles
        await model.authStore.refreshAll(targets, binary: try claudeBinary())
        var allSignedIn = true
        let rows = targets.map { profile -> [Cell] in
            guard let status = model.authStore.status(for: profile.id) else {
                allSignedIn = false
                return [Cell(profile.name), Cell("unknown", .yellow), Cell(model.authStore.errors[profile.id] ?? "", .dim)]
            }
            guard status.signedIn else {
                allSignedIn = false
                return [Cell(profile.name), Cell("signed out", .red), Cell("claude-pool login \(profile.slug)", .dim)]
            }
            let parts = [
                status.email ?? status.identityLabel,
                model.authStore.plan(for: profile.id)?.displayName,
                status.reportsUsage ? nil : status.authMethodLabel,
            ]
            return [Cell(profile.name), Cell("signed in", .green), Cell(parts.compactMap { $0 }.joined(separator: " · "))]
        }
        write(table(["ACCOUNT", "SIGN-IN", "AS"], rows))
        return allSignedIn ? 0 : 1
    }

    private func usage(_ query: String?, check: Bool) async throws -> Int32 {
        let targets = try query.map { [try account($0)] } ?? profiles
        var failed = false
        if check {
            model.useBinary(try claudeBinary())
            for profile in targets where profile.trackingEnabled {
                writeError(paint("Checking \(profile.name)…\n", .dim))
                do {
                    try await model.checkUsageNow(profile)
                } catch {
                    warn("\(profile.name): \(error.localizedDescription)")
                    failed = true
                }
            }
        }
        let formatting = model.formatting
        for profile in targets {
            write(paint(profile.name, .bold) + "\n")
            guard profile.trackingEnabled else {
                write("  " + paint("Usage tracking is off. Turn it on in Claude Pool.", .dim) + "\n")
                continue
            }
            for kind in UsageWindowKind.allCases {
                let state = model.usageState(profile, kind)
                if let window = state.displayedWindow {
                    let percent = UsageFormatting.percentText(window.usedPercentage).padding(toLength: 4, withPad: " ", startingAt: 0)
                    let observed = formatting.observationText(state).map { "  (\($0))" } ?? ""
                    write("  \(kind.shortLabel)  \(paint(percent, level(window.usedPercentage)))  \(formatting.resetText(window, kind: kind))\(paint(observed, .dim))\n")
                } else {
                    write("  \(kind.shortLabel)  –     \(paint(formatting.stateText(state, kind: kind) ?? "", .dim))\n")
                }
            }
        }
        return failed ? 1 : 0
    }

    private func rename(_ query: String, to name: String, slug: String?) throws -> Int32 {
        var profile = try account(query)
        let old = profile.name
        profile.name = name
        if let slug { profile.slug = slug }
        try model.profileStore.update(profile)
        notifyApp()
        say("Renamed \(old) to \(profile.name.trimmingCharacters(in: .whitespacesAndNewlines)).")
        return 0
    }

    private func remove(_ query: String, trash: Bool, confirmed: Bool) throws -> Int32 {
        let profile = try account(query)
        guard !profile.isDefault else { throw ProfileValidationError.defaultNotDeletable }
        let folder = paths.abbreviate(profile.configDir)
        if !confirmed {
            guard interactive else { throw CLIError.usage("Add --yes to remove \(profile.name) without being asked.") }
            write("Remove \(profile.name) from Claude Pool? "
                  + (trash ? "Its folder \(folder) goes to the Trash." : "Its folder \(folder) and its sign-in are kept.")
                  + " [y/N] ")
            let answer = readAnswer()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                say("Nothing was removed.")
                return 1
            }
        }
        try model.deleteProfile(profile, moveDirectoryToTrash: trash, restoreSettings: true)
        try? model.writeProfileDirectories()
        notifyApp()
        say("Removed \(profile.name)." + (trash ? " Its folder is in the Trash." : ""))
        return 0
    }

    private func env(_ query: String?) throws -> Int32 {
        let profile = try account(query)
        if let directory = profile.configDirEnvironmentValue {
            write("export CLAUDE_CONFIG_DIR=\(ShellQuote.quote(directory))\n")
        } else {
            // The shell integration sends a plain claude to the active account when the variable is
            // unset, so this shell also needs a claude that skips it.
            write("unset CLAUDE_CONFIG_DIR\nclaude() { command claude \"$@\"; }\n")
        }
        if interactive { write(paint("# Apply it to this shell with: eval \"$(claude-pool env \(profile.slug))\"\n", .dim)) }
        return 0
    }

    private func projects() throws -> Int32 {
        guard let folder = settings.projectsFolder else {
            throw CLIError(message: "No projects folder is set. Choose one in Claude Pool › Settings › Terminal.")
        }
        for name in projectNames(in: paths.expandTilde(folder)) { write(name + "\n") }
        return 0
    }

    private func sessions() -> Int32 {
        let sessions = SessionRegistryService().sessions(for: profiles)
        guard !sessions.isEmpty else {
            say("No claude sessions are running.")
            return 0
        }
        let formatting = UsageFormatting(now: Date())
        let rows = sessions.map { session -> [Cell] in
            [
                Cell(model.profileStore.profile(id: session.profileID)?.name ?? "?"),
                Cell("\(session.pid)", .dim),
                Cell(session.status ?? "", session.isBusy ? .yellow : nil),
                Cell(paths.abbreviate(session.cwd)),
                Cell(session.startedAt.map { formatting.age(since: $0) } ?? "", .dim),
            ]
        }
        write(table(["ACCOUNT", "PID", "STATE", "FOLDER", "STARTED"], rows))
        return 0
    }

    // MARK: Accounts, folders and claude

    private func account(_ query: String) throws -> Profile {
        try AccountQuery.resolve(query, in: profiles)
    }

    /// The named account, or the active one when no name was given.
    private func account(_ query: String?) throws -> Profile {
        guard let query else { return try activeAccount() }
        return try account(query)
    }

    private func activeAccount() throws -> Profile {
        guard let active = model.profileStore.activeProfile else {
            let directory = model.profileStore.unknownActiveDirectory.map(paths.abbreviate) ?? "unknown"
            throw CLIError(message: "The active account is \(directory), which isn't in Claude Pool. Name an account, or choose one with claude-pool use.")
        }
        return active
    }

    /// This environment with the profile's `CLAUDE_CONFIG_DIR` (unset for Default).
    private func claudeEnvironment(for profile: Profile) -> [String: String] {
        var environment = environment
        environment["CLAUDE_CONFIG_DIR"] = profile.configDirEnvironmentValue
        return environment
    }

    /// The Settings override, then `claude` on this shell's PATH, then the usual install locations.
    func claudeBinary() throws -> ClaudeBinary {
        let fm = FileManager.default
        func isProgram(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.isExecutableFile(atPath: path) && fm.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        if let override = settings.claudePathOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty,
           isProgram(paths.expandTilde(override)) {
            return ClaudeBinary(path: paths.expandTilde(override), source: .userOverride)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let path = "\(directory)/claude"
            if isProgram(path) { return ClaudeBinary(path: path, source: .loginShell) }
        }
        if let path = model.locator.fallbackPaths.first(where: isProgram) {
            return ClaudeBinary(path: path, source: .fallback)
        }
        throw CLIError(message: "Claude Code wasn't found on your PATH. Install it, or set its path in Claude Pool › Settings › Claude Code.")
    }

    /// A path (relative to this directory, or with ~), or a folder in the projects folder: its
    /// name in any case, or the start of a name only one folder has.
    private func resolveFolder(_ value: String) throws -> String {
        let path = absolutePath(value)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return path }
        let projects = settings.projectsFolder.map(paths.expandTilde)
        if let projects, !value.contains("/") {
            let names = projectNames(in: projects)
            let lowered = value.lowercased()
            let matches = names.first { $0.lowercased() == lowered }.map { [$0] } ?? names.filter { $0.lowercased().hasPrefix(lowered) }
            if matches.count == 1 { return URL(fileURLWithPath: projects).appendingPathComponent(matches[0]).path }
            if matches.count > 1 {
                let shown = matches.prefix(8).joined(separator: ", ") + (matches.count > 8 ? ", …" : "")
                throw CLIError(message: "“\(value)” could be \(shown). Type more of the name.")
            }
        }
        throw CLIError(message: "No folder “\(value)” here" + (projects.map { " or in \(paths.abbreviate($0))" } ?? "") + ".")
    }

    private func absolutePath(_ value: String) -> String {
        let expanded = paths.expandTilde(value)
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: currentDirectory).appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }

    /// Folders (not hidden) in the projects folder, sorted as Finder sorts them.
    private func projectNames(in folder: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return !name.hasPrefix(".") && fm.fileExists(atPath: "\(folder)/\(name)", isDirectory: &isDirectory) && isDirectory.boolValue
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A preset name (any case) or #RRGGBB.
    private func colorHex(_ value: String) throws -> String {
        if let preset = ProfileColor.presets.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) { return preset.hex }
        let hex = value.hasPrefix("#") ? value : "#" + value
        guard hex.count == 7, hex.dropFirst().allSatisfy(\.isHexDigit) else {
            let names = ProfileColor.presets.map { $0.name.lowercased() }.joined(separator: ", ")
            throw CLIError.usage("Unknown color \(value). Use \(names) or #RRGGBB.")
        }
        return hex.uppercased()
    }

    private func plan(_ details: AccountDetails?) -> String? {
        SubscriptionPlan.resolve(subscriptionType: nil, details: details, signedInEmail: nil)?.displayName
    }

    // MARK: Output

    struct AccountSummary: Encodable {
        struct Window: Encodable {
            var usedPercentage: Double
            var resetsAt: Date
        }

        var number: Int
        var name: String
        var slug: String
        var active: Bool
        var isDefault: Bool
        var directory: String
        var email: String?
        var plan: String?
        var usageTracking: Bool
        var fiveHour: Window?
        var sevenDay: Window?
    }

    private enum Style: String {
        case bold = "1", dim = "2", red = "31", green = "32", yellow = "33"
    }

    private struct Cell {
        var text: String
        var style: Style?

        init(_ text: String, _ style: Style? = nil) {
            self.text = text
            self.style = style
        }
    }

    private func paint(_ text: String, _ style: Style?) -> String {
        guard colors, let style, !text.isEmpty else { return text }
        return "\u{1B}[\(style.rawValue)m\(text)\u{1B}[0m"
    }

    private func level(_ percent: Double) -> Style? {
        switch UsageFormatting.level(for: percent) {
        case .normal: nil
        case .elevated: .yellow
        case .critical: .red
        }
    }

    private func usageCell(_ profile: Profile, _ kind: UsageWindowKind) -> Cell {
        guard let window = model.usageState(profile, kind).displayedWindow else { return Cell("–", .dim) }
        return Cell(UsageFormatting.percentText(window.usedPercentage), level(window.usedPercentage))
    }

    /// Left-aligned columns two spaces apart, with a dim header.
    private func table(_ header: [String], _ rows: [[Cell]]) -> String {
        let all = [header.map { Cell($0, .dim) }] + rows
        let widths = header.indices.map { column in all.map { $0[column].text.count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { column, cell in
                let text = column == row.count - 1 ? cell.text : cell.text.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                return paint(text, cell.style)
            }
            .joined(separator: "  ")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        .joined(separator: "\n") + "\n"
    }

    private func say(_ text: String) {
        write(text + "\n")
    }

    private func hint(_ text: String) {
        write(paint(text, .dim) + "\n")
    }

    private func warn(_ text: String) {
        writeError("claude-pool: \(text)\n")
    }
}
