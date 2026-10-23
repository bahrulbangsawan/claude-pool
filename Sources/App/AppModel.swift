import AppKit
import Foundation
import Observation

/// Owns the stores and services and implements every user action. Switching is only ever
/// triggered by these explicit actions; usage values only feed the opt-in limit notifications and
/// the opt-in suggestion, which never switch anything themselves.
@MainActor
@Observable
final class AppModel {
    let paths: Paths
    let settingsStore: AppSettingsStore
    let profileStore: ProfileStore
    let usageStore: UsageStore
    let authStore: AuthStore
    let sessionStore: SessionStore
    let analyticsStore: AnalyticsStore
    let statuslineStore: StatuslineStore
    let mcpStore: McpStore
    let resourceStore = ResourceStore()

    private(set) var binary: ClaudeBinary?
    private(set) var isLocatingBinary = false
    private(set) var shellStatus: ShellIntegrationStatus = .notInstalled
    private(set) var collectorState: CollectorInstallState = .missing
    private(set) var trackingStates: [UUID: TrackingState] = [:]
    private(set) var diagnostics: [DiagnosticCheck] = []
    private(set) var isRunningDiagnostics = false
    private(set) var isInstallingHerdr = false
    var herdrInstallError: String?
    /// Profiles with a "Check usage now" request running.
    private(set) var checkingUsage: Set<UUID> = []
    private(set) var diagnosticsRunAt: Date?
    var startupError: String?
    /// Last shared-extensions sync: when it ran, what it changed, or why it failed.
    private(set) var sharedSyncAt: Date?
    private(set) var sharedSyncChanges: [String] = []
    private(set) var sharedSyncError: String?
    /// What the last update check found; see `checkForUpdates`.
    private(set) var updateState: UpdateState = .idle
    /// Whether that check came from Check for Updates… (the menu shows only those results).
    private(set) var updateCheckWasManual = false
    private(set) var lastUpdateCheck: Date?
    /// The `claude-pool` link on the PATH; see `CommandLineInstaller`.
    private(set) var commandLineState: CommandLineInstallState = .notInstalled
    private(set) var isChangingCommandLine = false
    var commandLineError: String?

    /// What the manager window shows; the menu's warning row jumps to Diagnostics.
    var route: ManagerRoute = .overview
    var trackingRequest: TrackingRequest?
    var trackingError: String?
    /// The in-app sign-in currently shown, if any.
    var loginFlow: LoginFlow?
    /// Asks the manager window to show the in-app sign-in for this profile.
    var signInRequest: Profile?
    /// The MCP server sign-ins currently shown, if any.
    var mcpSignIn: McpSignInQueue?
    /// Last pointer value read back after a switch (nil = Default); `pointerError` if unreadable.
    private(set) var pointerOnDisk: String?
    private(set) var pointerError: String?
    /// Whether macOS lets Claude Pool post notifications (for the opt-in limit alerts).
    private(set) var notificationAuthorization: LimitNotifier.Authorization = .unavailable
    /// Profiles whose status line should switch to "managed" once tracking is confirmed.
    @ObservationIgnored private var manageAfterTracking: Set<UUID> = []

    @ObservationIgnored let shell: ShellIntegrationService
    @ObservationIgnored let launcher: TerminalLauncher
    @ObservationIgnored let patcher: SettingsPatcher
    @ObservationIgnored let installer: CollectorInstaller
    @ObservationIgnored let locator: ClaudeBinaryLocator
    @ObservationIgnored let diagnosticsService: DiagnosticsService
    @ObservationIgnored let handoffService = SessionHandoffService()
    @ObservationIgnored let loginItem = LoginItemService()
    @ObservationIgnored let notifier = LimitNotifier()
    @ObservationIgnored let updater: UpdateService
    @ObservationIgnored let commandLine: CommandLineInstaller
    @ObservationIgnored private var alertTracker = LimitAlertTracker()
    @ObservationIgnored private var maintenanceTimer: Timer?
    @ObservationIgnored private var sharedSyncTimer: Timer?
    @ObservationIgnored private var sharedSyncTask: Task<Void, Never>?
    @ObservationIgnored private var sharedSyncPending = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var commandLineObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false
    /// Off only in UI snapshots, so sample sign-in states are not replaced by live checks.
    @ObservationIgnored var liveChecksEnabled = true
    @ObservationIgnored private var locateTask: Task<Void, Never>?

    init(paths: Paths, loginShell: String = ShellIntegrationService.currentLoginShell(), bundledHelper: URL = CollectorInstaller.bundledHelperURL()) {
        self.paths = paths
        settingsStore = AppSettingsStore(paths: paths)
        profileStore = ProfileStore(paths: paths)
        usageStore = UsageStore(pool: paths.pool)
        authStore = AuthStore(service: AuthStatusService(home: paths.userHome))
        sessionStore = SessionStore()
        analyticsStore = AnalyticsStore(indexURL: paths.appSupport.appendingPathComponent("usage-index.sqlite"))
        statuslineStore = StatuslineStore(pool: paths.pool, presetsFile: paths.appSupport.appendingPathComponent("statusline-presets.json"))
        mcpStore = McpStore(service: McpService(home: paths.userHome, loginShell: loginShell))
        shell = ShellIntegrationService(home: paths.userHome, loginShell: loginShell)
        launcher = TerminalLauncher(paths: paths)
        patcher = SettingsPatcher(pool: paths.pool)
        installer = CollectorInstaller(pool: paths.pool, bundledHelper: bundledHelper)
        locator = ClaudeBinaryLocator(home: paths.userHome)
        diagnosticsService = DiagnosticsService(home: paths.userHome, loginShell: loginShell)
        updater = UpdateService(home: paths.userHome, workDirectory: paths.caches.appendingPathComponent("Updates", isDirectory: true))
        commandLine = CommandLineInstaller(
            home: paths.userHome,
            executable: Bundle.main.executableURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ClaudePool"),
            loginShell: loginShell
        )
    }

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    var profiles: [Profile] { profileStore.profiles }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        settingsStore.load()
        profileStore.load()
        profileStore.onSave = { [weak self] in
            self?.syncSharedExtensions()
            try? self?.writeProfileDirectories()
        }
        syncSharedExtensions()
        do {
            try AtomicFile.ensureDirectory(paths.pool.home, permissions: 0o700)
            try writeProfileDirectories()
            try installer.installIfNeeded()
            try installer.writeOutputMode(settings.collectorOutput)
        } catch {
            startupError = error.localizedDescription
        }
        collectorState = installer.state()
        launcher.cleanUpOldScripts()
        updater.cleanUp()
        usageStore.start()
        // Records current levels without notifying, so a launch never repeats old alerts.
        checkLimitAlerts()
        notifier.activate()
        pruneHistoryIfDue()
        refreshLocalState()
        statuslineStore.load(profiles: profiles)
        authStore.reloadDetails(profiles)
        // A status line run or a session starting/ending means new usage may have been recorded.
        usageStore.onActivity = { [weak self] in
            self?.analyticsStore.noteActivity()
            self?.checkLimitAlerts()
        }
        var lastSessionIDs: Set<String> = []
        sessionStore.onRefresh = { [weak self] in
            guard let self else { return }
            let ids = Set(self.sessionStore.sessions.map(\.id))
            if ids != lastSessionIDs { lastSessionIDs = ids; self.analyticsStore.noteActivity() }
            self.reloadPointer()
        }
        if liveChecksEnabled {
            sessionStore.start { [weak self] in self?.profiles ?? [] }
            analyticsStore.start { [weak self] in self?.profiles ?? [] }
            resourceStore.start { [weak self] in self?.sessionStore.sessions.map(\.pid) ?? [] }
            Task { await refreshNotificationAuthorization() }
        }

        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodicMaintenance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer

        // Picks up extensions installed or removed from inside a session.
        let syncTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncSharedExtensions() }
        }
        RunLoop.main.add(syncTimer, forMode: .common)
        sharedSyncTimer = syncTimer

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.appDidBecomeActive() }
        }

        commandLineObserver = DistributedNotificationCenter.default().addObserver(
            forName: CommandLineTool.profilesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadProfiles() }
        }

        // Mark as locating before the first frame so the "not found" banner never flashes.
        isLocatingBinary = true
        Task {
            await locateBinary()
            await runDiagnostics()
            await checkForUpdatesIfDue()
        }
    }

    func appDidBecomeActive() async {
        syncSharedExtensions()
        usageStore.reload()
        refreshLocalState()
        await authStore.refreshIfStale(profiles, binary: await resolvedBinary())
    }

    /// Manager window opened: sign-in status for all profiles, then diagnostics.
    func managerWindowOpened() async {
        guard liveChecksEnabled else { return }
        usageStore.reload()
        refreshLocalState()
        await authStore.refreshAll(profiles, binary: await resolvedBinary())
        await runDiagnostics()
    }

    /// Runs the locator; concurrent callers share one in-flight lookup.
    func locateBinary() async {
        if let locateTask { return await locateTask.value }
        isLocatingBinary = true
        let override = settings.claudePathOverride
        let task = Task { @MainActor [locator] in
            self.binary = await locator.locate(override: override)
        }
        locateTask = task
        await task.value
        locateTask = nil
        isLocatingBinary = false
    }

    /// Uses a binary found some other way: the claude-pool command takes the one on its own PATH,
    /// which is quicker than asking a login shell.
    func useBinary(_ binary: ClaudeBinary) {
        self.binary = binary
    }

    /// The binary, waiting for a lookup that is still running (or starting one if never located).
    /// Sign-in checks use this so they never run while the binary is still being located.
    func resolvedBinary() async -> ClaudeBinary? {
        if let locateTask { await locateTask.value }
        else if binary == nil { await locateBinary() }
        return binary
    }

    /// Re-reads cheap local state: shell block, collector hash, statusLine keys.
    func refreshLocalState() {
        shellStatus = shell.status()
        commandLineState = commandLine.state()
        collectorState = installer.state()
        var states: [UUID: TrackingState] = [:]
        for profile in profiles { states[profile.id] = patcher.state(for: profile) }
        trackingStates = states
        profileStore.reloadActive()
        reloadPointer()
    }

    private func reloadPointer() {
        do {
            let value = try profileStore.pointer.read()
            if value != pointerOnDisk || pointerError != nil { pointerOnDisk = value; pointerError = nil }
            profileStore.reloadActive()
        } catch {
            pointerError = error.localizedDescription
        }
    }

    /// Every 5 minutes: history pruning (daily), plan data re-read, status line context.
    private func periodicMaintenance() {
        pruneHistoryIfDue()
        authStore.reloadDetails(profiles)
        syncStatuslineContext()
        Task { await checkForUpdatesIfDue() }
    }

    private func pruneHistoryIfDue() {
        let now = Date()
        if let last = settings.lastHistoryPrune, now.timeIntervalSince(last) < 24 * 60 * 60 { return }
        usageStore.pruneHistory(now: now)
        settings.lastHistoryPrune = now
    }

    // MARK: Switching (manual only)

    func setActive(_ profile: Profile) {
        syncSharedExtensions()
        profileStore.setActive(profile.id)
        // Read back what new launches will actually read; the UI reports the file, not intent.
        reloadPointer()
        if liveChecksEnabled {
            Task { await refreshAuth(profile) }
        }
    }

    /// Whether a `claude` started now (through the shell integration or Open Terminal) would use
    /// `profile`'s account. Based on the pointer file on disk and a fresh sign-in check.
    func launchReadiness(for profile: Profile) -> LaunchReadiness {
        if let pointerError { return .pointerUnreadable(pointerError) }
        let expected = profile.configDirEnvironmentValue
        let matches = switch (pointerOnDisk, expected) {
        case (nil, nil): true
        case let (actual?, expected?): Paths.canonical(actual) == Paths.canonical(expected)
        default: false
        }
        guard matches else { return .pointerMismatch(pointerOnDisk) }
        if authStore.refreshing.contains(profile.id) { return .checking }
        if let error = authStore.errors[profile.id] { return .unverified(error) }
        guard let status = authStore.status(for: profile.id) else { return .checking }
        guard status.signedIn else { return .signedOut }
        if !status.reportsUsage { return .overridden(status.authMethodLabel) }
        if let reported = status.configDirectory, Paths.canonical(reported) != Paths.canonical(profile.configDir) {
            return .isolationBroken(reported)
        }
        return .ready(status)
    }

    /// Live sessions on other profiles than the active one: they keep their own account.
    var sessionsOnOtherProfiles: [ClaudeSession] {
        sessionStore.sessions(notOn: profileStore.activeProfileID)
    }

    // MARK: Session handoff

    /// Continues a running conversation on another profile: re-checks the target's sign-in, copies
    /// the conversation into the target profile, then opens Terminal (or a herdr tab) with
    /// `claude --resume <id>` in the session's folder. The original process is left alone.
    func handOff(_ session: ClaudeSession, to target: Profile) async throws {
        guard let binary = await resolvedBinary() else { throw AppModelError.binaryMissing }
        guard let source = profileStore.profile(id: session.profileID) else { throw ProfileValidationError.notFound }
        await authStore.refresh(target, binary: binary)
        guard let status = authStore.status(for: target.id), status.signedIn else {
            throw AppModelError.targetNotReady(target.name, authStore.errors[target.id] ?? "it is signed out")
        }
        guard status.reportsUsage else {
            throw AppModelError.targetNotReady(target.name, "it uses \(status.authMethodLabel) instead of a claude.ai sign-in")
        }
        let plan = try handoffService.plan(session, from: source, to: target)
        let result = try handoffService.execute(plan)
        await analyticsStore.registerCopiedFiles(result.copiedFiles, profileID: target.id)
        try await launcher.launch(target, workingDirectory: session.cwd, claudePath: binary.path, arguments: ["--resume", session.sessionID], in: settings.terminalHost)
        sessionStore.beginHandoff(session, to: target.id)
    }

    /// Asks a session's process to exit (SIGTERM), after re-checking it is still that session and idle.
    func endSession(_ session: ClaudeSession) throws {
        guard let profile = profileStore.profile(id: session.profileID),
              let current = sessionStore.registry.sessions(for: profile).first(where: { $0.pid == session.pid && $0.sessionID == session.sessionID }) else {
            throw AppModelError.sessionGone
        }
        guard !current.isBusy else { throw AppModelError.sessionBusy }
        guard kill(current.pid, SIGTERM) == 0 else { throw AppModelError.sessionGone }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.sessionStore.refresh()
        }
    }

    /// ⌘1–⌘9 in the menu panel: the Nth profile in the user's order.
    func setActive(index: Int) {
        guard profiles.indices.contains(index) else { return }
        setActive(profiles[index])
    }

    // MARK: Terminal

    /// Opens Terminal (or a herdr tab) running `claude` with `profile`, in `folder` (a project
    /// picked from the projects folder) or else the working directory from Settings. A project
    /// names the window or tab together with the profile: "mokanata · Work".
    func openTerminal(_ profile: Profile, in folder: String? = nil, forSignIn: Bool = false) async throws {
        if let folder {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: paths.expandTilde(folder), isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AppModelError.folderMissing(paths.abbreviate(folder))
            }
        }
        guard let binary else { throw AppModelError.binaryMissing }
        let title = folder.map { "\(URL(fileURLWithPath: $0).lastPathComponent) · \(profile.name)" }
        try await launcher.launch(profile, workingDirectory: folder ?? settings.defaultWorkingDirectory, claudePath: binary.path, title: title, in: settings.terminalHost)
        if forSignIn {
            authStore.scheduleCheckAfterSignIn(profile) { [weak self] in self?.binary }
        }
    }

    // MARK: Updates

    static let updateCheckInterval: TimeInterval = 6 * 60 * 60

    /// Automatic checks: at launch, then every 6 hours, while Update automatically is on. A failed
    /// check (offline) is retried at the next maintenance tick.
    func checkForUpdatesIfDue(now: Date = Date()) async {
        guard liveChecksEnabled, settings.updateAutomatically else { return }
        if let lastUpdateCheck, now.timeIntervalSince(lastUpdateCheck) < Self.updateCheckInterval { return }
        await checkForUpdates(manual: false)
    }

    /// Asks GitHub for the latest release. An automatic check installs a newer one right away;
    /// Check for Updates… only reports it, and Install and Relaunch installs it.
    func checkForUpdates(manual: Bool = true) async {
        guard !isUpdating else { return }
        updateCheckWasManual = manual
        updateState = .checking
        do {
            let release = try await updater.latestRelease()
            lastUpdateCheck = Date()
            guard let current = AppVersion.current, release.version > current else {
                updateState = .upToDate
                return
            }
            updateState = .available(release)
            if !manual, canUpdateAutomatically { await installUpdate(release) }
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    /// A check or an install is running.
    var isUpdating: Bool {
        switch updateState {
        case .checking, .installing: true
        default: false
        }
    }

    /// Never in the middle of a sign-in, and only for a copy in an Applications folder, so a
    /// development build is never replaced behind the developer's back.
    private var canUpdateAutomatically: Bool {
        loginFlow == nil && Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
    }

    /// Downloads and verifies `release`, puts it next to this app, and quits; a small script swaps
    /// the two once Claude Pool has quit and opens the new version. Running claude sessions are
    /// separate processes and keep running.
    func installUpdate(_ release: AppRelease) async {
        guard !isUpdating else { return }
        updateState = .installing(release)
        do {
            guard let bundleID = Bundle.main.bundleIdentifier else {
                throw UpdateError.cannotInstall("this copy of Claude Pool has no bundle identifier.")
            }
            let staged = try await updater.download(release, bundleIdentifier: bundleID)
            try await updater.install(staged, over: Bundle.main.bundleURL, waitingFor: getpid())
            NSApp.terminate(nil)
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    func dismissUpdateMessage() {
        updateCheckWasManual = false
        if case .failed = updateState { updateState = .idle }
    }

    /// Installs herdr with its official installer, for Open in › herdr.
    func installHerdr() async {
        guard !isInstallingHerdr else { return }
        isInstallingHerdr = true
        defer { isInstallingHerdr = false }
        do {
            _ = try await launcher.herdr.install()
            herdrInstallError = nil
        } catch {
            herdrInstallError = error.localizedDescription
        }
    }

    // MARK: In-app sign-in

    /// Starts Claude Code's own sign-in for `profile` without Terminal; see `LoginFlow`.
    @discardableResult
    func beginLogin(for profile: Profile, emailHint: String? = nil) async throws -> LoginFlow {
        guard let binary = await resolvedBinary() else { throw AppModelError.binaryMissing }
        loginFlow?.cancel()
        let previous = authStore.status(for: profile.id).flatMap { $0.signedIn ? $0.email : nil }
        let flow = LoginFlow(profile: profile, binary: binary, paths: paths, previousIdentity: previous) { [weak self] profile in
            guard let self else { return nil }
            await self.authStore.refresh(profile, binary: binary)
            self.syncStatuslineContext()
            self.syncSharedExtensions()
            return self.authStore.status(for: profile.id)
        }
        loginFlow = flow
        flow.start(emailHint: emailHint)
        return flow
    }

    // MARK: Sign-in status

    func refreshAuth(_ profile: Profile) async {
        await authStore.refresh(profile, binary: await resolvedBinary())
        syncStatuslineContext()
    }

    func refreshAllAuth() async {
        await authStore.refreshAll(profiles, binary: await resolvedBinary())
        syncStatuslineContext()
    }

    // MARK: MCP servers

    /// Checks the profiles whose server list is missing or a few minutes old (MCP Servers page).
    func refreshMcpIfStale() async {
        guard liveChecksEnabled else { return }
        await mcpStore.refreshIfStale(profiles, binary: await resolvedBinary())
    }

    /// Checks every profile's servers again, or only `profile`'s.
    func refreshMcp(_ profile: Profile? = nil) async {
        let binary = await resolvedBinary()
        if let profile { await mcpStore.refresh(profile, binary: binary) }
        else { await mcpStore.refreshAll(profiles, binary: binary) }
    }

    /// Profile × server pairs waiting for a sign-in, server by server.
    var pendingMcpSignIns: [McpSignInStep] { mcpStore.pendingSignIns(for: profiles) }

    /// Shows the MCP sign-in sheet and starts the first of `steps`; see `McpSignInQueue`.
    func beginMcpSignIn(_ steps: [McpSignInStep]) async throws {
        guard !steps.isEmpty else { return }
        guard let binary = await resolvedBinary() else { throw AppModelError.binaryMissing }
        mcpSignIn?.cancel()
        let home = paths.userHome
        var environments: [UUID: [String: String]] = [:]
        for profile in steps.map(\.profile) where environments[profile.id] == nil {
            environments[profile.id] = await mcpStore.service.environment(for: profile, binary: binary)
        }
        let queue = McpSignInQueue(steps: steps) { [weak self] step in
            McpLoginFlow(profile: step.profile, serverName: step.serverName, binary: binary, home: home,
                         environment: environments[step.profile.id] ?? [:]) { profile, name in
                await self?.mcpStore.recheck(name, on: profile, binary: binary)
            }
        }
        mcpSignIn = queue
        queue.start()
    }

    struct McpAddResult {
        /// Profiles where the new server waits for a sign-in.
        var needingSignIn: [Profile] = []
        /// "Work: <reason>" for each profile where adding failed.
        var failures: [String] = []
    }

    /// Adds a remote server with Claude Code's `claude mcp add --scope user` to each of `targets`
    /// (every profile while Shared Extensions is on, which would copy it everywhere anyway), then
    /// reads its state back from each.
    func addMcpServer(name: String, url: String, transport: McpTransport, to targets: [Profile]) async throws -> McpAddResult {
        guard let binary = await resolvedBinary() else { throw AppModelError.binaryMissing }
        let targets = settings.shareExtensions ? profiles : targets
        var result = McpAddResult()
        var added: [Profile] = []
        for profile in targets {
            do {
                _ = try await mcpStore.service.add(name: name, url: url, transport: transport, profile: profile, binary: binary)
                added.append(profile)
            } catch {
                result.failures.append("\(profile.name): \(error.localizedDescription)")
            }
        }
        if added.isEmpty, let first = result.failures.first { throw McpServiceError.failed(first) }
        // Read the new server back from every profile at once (`claude mcp get` checks it).
        let service = mcpStore.service
        var states: [UUID: McpServer] = [:]
        await withTaskGroup(of: (Profile, McpServer?).self) { group in
            for profile in added {
                group.addTask { (profile, (try? await service.get(name, profile: profile, binary: binary)) ?? nil) }
            }
            for await (profile, server) in group {
                states[profile.id] = server
                mcpStore.apply(server, named: name, for: profile.id)
            }
        }
        result.needingSignIn = added.filter { states[$0.id]?.health == .needsSignIn }
        syncSharedExtensions()
        return result
    }

    /// Removes a server you added from each of `targets` (every profile while Shared Extensions is
    /// on, so the sync doesn't bring it back).
    func removeMcpServer(_ name: String, from targets: [Profile]) async throws {
        guard let binary = await resolvedBinary() else { throw AppModelError.binaryMissing }
        let targets = settings.shareExtensions ? profiles : targets
        var failures: [String] = []
        for profile in targets {
            do { try await mcpStore.remove(name, from: profile, binary: binary) }
            catch { failures.append("\(profile.name): \(error.localizedDescription)") }
        }
        syncSharedExtensions()
        if !failures.isEmpty { throw McpServiceError.failed(failures.joined(separator: "\n")) }
    }

    /// Has Claude Code forget the server's sign-in in each of `targets`.
    func signOutMcpServer(_ name: String, on targets: [Profile]) async throws {
        guard let binary = await resolvedBinary() else { throw AppModelError.binaryMissing }
        var failures: [String] = []
        for profile in targets {
            do { try await mcpStore.signOut(name, on: profile, binary: binary) }
            catch { failures.append("\(profile.name): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw McpServiceError.failed(failures.joined(separator: "\n")) }
    }

    // MARK: Usage tracking opt-in

    var collectorPath: String { paths.pool.installedCollector.path }

    func previewEnableTracking(_ profile: Profile) throws -> StatusLinePreview {
        try patcher.previewEnable(profile, collectorPath: collectorPath)
    }

    func previewDisableTracking(_ profile: Profile) throws -> StatusLinePreview {
        try patcher.previewDisable(profile)
    }

    func enableTracking(_ profile: Profile) throws {
        try installer.installIfNeeded()
        collectorState = installer.state()
        var updated = profile
        switch try patcher.enable(profile, collectorPath: collectorPath) {
        case let .patched(original):
            updated.originalStatusLine = original
        case .alreadyEnabled:
            break
        }
        updated.trackingEnabled = true
        try profileStore.update(updated)
        trackingStates[profile.id] = patcher.state(for: updated)
        if manageAfterTracking.remove(profile.id) != nil {
            try setStatuslineManaged(true, for: updated)
        }
    }

    func disableTracking(_ profile: Profile) throws {
        // Without the collector nothing renders the managed layout; keep the flag consistent.
        if statuslineStore.isManaged(profile.id) { try statuslineStore.setManaged(false, for: profile, account: nil, plan: nil) }
        try patcher.disable(profile)
        var updated = profile
        updated.trackingEnabled = false
        updated.originalStatusLine = nil
        try profileStore.update(updated)
        trackingStates[profile.id] = patcher.state(for: updated)
    }

    func trackingState(for profile: Profile) -> TrackingState {
        trackingStates[profile.id] ?? (profile.trackingEnabled ? .enabled : .disabled)
    }

    /// Opens the confirmation sheet with before/after values; nothing is written yet.
    func requestTrackingChange(_ profile: Profile, enable: Bool) {
        do {
            let preview = enable ? try previewEnableTracking(profile) : try previewDisableTracking(profile)
            trackingError = nil
            trackingRequest = TrackingRequest(profile: profile, enable: enable, preview: preview)
        } catch {
            trackingError = error.localizedDescription
        }
    }

    func confirmTrackingChange(_ request: TrackingRequest) {
        do {
            // Use the latest stored copy (e.g. the name may have changed while the sheet was open).
            let profile = profileStore.profile(id: request.profile.id) ?? request.profile
            if request.enable { try enableTracking(profile) } else { try disableTracking(profile) }
            trackingError = nil
        } catch {
            trackingError = error.localizedDescription
        }
        trackingRequest = nil
        if !request.enable || trackingError != nil { manageAfterTracking.remove(request.profile.id) }
    }

    func cancelTrackingRequest() {
        if let request = trackingRequest { manageAfterTracking.remove(request.profile.id) }
        trackingRequest = nil
    }

    // MARK: Status line manager

    /// Renders the applied layout for this profile. Needs the collector as its statusLine (the same
    /// opt-in as usage tracking); if it isn't there yet, the tracking confirmation is shown first.
    func setStatuslineManaged(_ managed: Bool, for profile: Profile) throws {
        if managed, trackingState(for: profile) != .enabled {
            manageAfterTracking.insert(profile.id)
            requestTrackingChange(profile, enable: true)
            return
        }
        if managed, statuslineStore.applied == nil { try statuslineStore.apply() }
        try statuslineStore.setManaged(managed, for: profile, account: statuslineAccount(profile), plan: authStore.plan(for: profile.id)?.displayName)
    }

    private func statuslineAccount(_ profile: Profile) -> String? {
        authStore.status(for: profile.id).flatMap { $0.signedIn ? $0.email : nil }
    }

    func syncStatuslineContext() {
        for profile in profiles where statuslineStore.profileStates[profile.id] != nil {
            statuslineStore.syncContext(for: profile, account: statuslineAccount(profile), plan: authStore.plan(for: profile.id)?.displayName)
        }
    }

    // MARK: Display

    var formatting: UsageFormatting { UsageFormatting(now: usageStore.now) }

    func usageState(_ profile: Profile, _ kind: UsageWindowKind) -> UsageWindowState {
        UsageFormatting.state(
            for: kind,
            trackingEnabled: profile.trackingEnabled,
            auth: authStore.status(for: profile.id),
            snapshot: usageStore.snapshot(for: profile.id),
            now: usageStore.now
        )
    }

    /// "Check usage now" needs a tracked profile signed in with claude.ai (only those report usage).
    func canCheckUsage(_ profile: Profile) -> Bool {
        guard binary != nil, profile.trackingEnabled, let status = authStore.status(for: profile.id) else { return false }
        return status.signedIn && status.reportsUsage
    }

    /// Has Claude Code send one tiny request as `profile` and stores the usage it reports, the same
    /// way the collector stores a status line report. Costs a few hundred tokens of that account.
    func checkUsageNow(_ profile: Profile) async throws {
        guard !checkingUsage.contains(profile.id) else { return }
        guard let binary = await resolvedBinary() else { throw AppModelError.binaryMissing }
        checkingUsage.insert(profile.id)
        defer { checkingUsage.remove(profile.id) }
        let probe = UsageProbe(paths: paths)
        let reading = try await probe.check(profile, binary: binary)
        try installer.installIfNeeded()
        try await probe.record(reading, for: profile, collector: URL(fileURLWithPath: collectorPath))
        usageStore.reload()
    }

    /// Profiles whose saved sign-in names the same account as `profile`, while their usage resets
    /// at different times: they are different accounts, so one saved sign-in is out of date.
    func accountMismatches(for profile: Profile) -> [Profile] {
        let mine = usageStore.snapshot(for: profile.id)
        return authStore.duplicates(of: profile.id, among: profiles).filter {
            AccountMismatch.windowsDisagree(mine, usageStore.snapshot(for: $0.id), now: usageStore.now)
        }
    }

    // MARK: Limit alerts and suggestion (opt-in, informational only)

    func advisorCandidate(_ profile: Profile) -> AccountAdvisor.Candidate {
        AccountAdvisor.Candidate(profileID: profile.id,
                                 fiveHour: usageState(profile, .fiveHour),
                                 sevenDay: usageState(profile, .sevenDay),
                                 signedIn: authStore.status(for: profile.id)?.signedIn)
    }

    /// The account with the most room left while the active one is near or at a limit, when the
    /// suggestion is turned on. Choosing it is still the user's click.
    var suggestedProfile: Profile? {
        guard settings.suggestAccountEnabled else { return nil }
        return suggestedProfile(threshold: settings.limitAlertThreshold)
    }

    private func suggestedProfile(threshold: Int) -> Profile? {
        guard let active = profileStore.activeProfile else { return nil }
        let pick = AccountAdvisor.suggest(active: advisorCandidate(active),
                                          others: profiles.map(advisorCandidate), threshold: threshold)
        return pick.flatMap { profileStore.profile(id: $0.profileID) }
    }

    /// Compares the latest reported values with what was already announced; posts one notification
    /// per window and level (threshold, then 100%) per reset period when alerts are on.
    func checkLimitAlerts() {
        let observations = profiles.flatMap { profile in
            UsageWindowKind.allCases.map { LimitAlertTracker.Observation(profileID: profile.id, kind: $0, state: usageState(profile, $0)) }
        }
        let events = alertTracker.update(observations, threshold: settings.limitAlertThreshold)
        guard settings.limitAlertsEnabled else { return }
        for event in events {
            guard let profile = profileStore.profile(id: event.profileID) else { continue }
            let (title, body) = alertText(event, profile: profile)
            notifier.post(id: "limit-\(event.profileID.uuidString)-\(event.kind.rawValue)-\(event.level.rawValue)", title: title, body: body)
        }
    }

    func alertText(_ event: LimitAlertTracker.Event, profile: Profile) -> (title: String, body: String) {
        let window = event.kind == .fiveHour ? "5-hour" : "7-day"
        let title = event.level == .reached
            ? "\(profile.name) reached its \(window) limit"
            : "\(profile.name) is at \(event.percent)% of its \(window) limit"
        var body = "Resets \(formatting.clockText(event.resetsAt, for: event.kind)) (in \(formatting.countdown(to: event.resetsAt)))."
        if settings.suggestAccountEnabled, profile.id == profileStore.activeProfileID,
           let other = suggestedProfile(threshold: settings.limitAlertThreshold) {
            body += " Most room left: \(other.name) (\(usageSummary(other)))."
        }
        return (title, body)
    }

    /// "5h 12% · 7d 30%" from reported values; "–" for a window without one.
    func usageSummary(_ profile: Profile) -> String {
        UsageWindowKind.allCases.map { kind in
            "\(kind.shortLabel) \(usageState(profile, kind).displayedWindow.map { UsageFormatting.percentText($0.usedPercentage) } ?? "–")"
        }.joined(separator: " · ")
    }

    func refreshNotificationAuthorization() async {
        notificationAuthorization = await notifier.authorization()
    }

    /// Turns limit alerts on or off; turning on asks macOS for permission the first time.
    func setLimitAlerts(_ enabled: Bool) async {
        settings.limitAlertsEnabled = enabled
        guard enabled else { return }
        notificationAuthorization = await notifier.requestAuthorization()
    }

    // MARK: Profiles

    /// The claude-pool command changed profiles, a sign-in or the active profile: re-reads them and
    /// everything that depends on them.
    func reloadProfiles() {
        let before = Set(profiles.map(\.id))
        profileStore.load()
        for id in before.subtracting(profiles.map(\.id)) {
            authStore.forget(id)
            alertTracker.forget(id)
            trackingStates[id] = nil
            if loginFlow?.profile.id == id { loginFlow?.cancel(); loginFlow = nil }
            if route == .profile(id) { route = .overview }
        }
        try? writeProfileDirectories()
        refreshLocalState()
        usageStore.reload()
        statuslineStore.load(profiles: profiles)
        authStore.reloadDetails(profiles)
        syncSharedExtensions()
        if liveChecksEnabled {
            Task { await refreshAllAuth() }
        }
    }

    func deleteProfile(_ profile: Profile, moveDirectoryToTrash: Bool, restoreSettings: Bool) throws {
        if restoreSettings, profile.trackingEnabled {
            try patcher.disable(profile)
        }
        try profileStore.delete(profile.id, moveDirectoryToTrash: moveDirectoryToTrash)
        try? FileManager.default.removeItem(at: paths.pool.chainCommand(for: profile.id))
        usageStore.removeData(for: profile.id)
        alertTracker.forget(profile.id)
        authStore.forget(profile.id)
        statuslineStore.forget(profile.id)
        mcpStore.forget(profile.id)
        if loginFlow?.profile.id == profile.id { loginFlow?.cancel(); loginFlow = nil }
        if mcpSignIn?.steps.contains(where: { $0.profile.id == profile.id }) == true { mcpSignIn?.cancel(); mcpSignIn = nil }
        trackingStates[profile.id] = nil
        if route == .profile(profile.id) { route = .overview }
    }

    /// `.claude-*` directories in $HOME (excluding ~/.claude and plain files).
    func adoptableDirectories() -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.userHome.path) else { return [] }
        return names
            .filter { $0.hasPrefix(".claude-") && $0 != ".claude-pool" }
            .sorted()
            .map { paths.userHome.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
    }

    func isRegistered(directory: URL) -> Bool {
        profiles.contains { Paths.canonical($0.configDir) == Paths.canonical(directory.path) }
    }

    // MARK: Shell integration

    @discardableResult
    func installShellIntegration() throws -> URL? {
        defer { shellStatus = shell.status() }
        return try shell.install()
    }

    @discardableResult
    func uninstallShellIntegration() throws -> URL? {
        defer { shellStatus = shell.status() }
        return try shell.uninstall()
    }

    // MARK: Command line tool

    func installCommandLineTool() async {
        await changeCommandLine { try await $0.install() }
    }

    func uninstallCommandLineTool() async {
        await changeCommandLine { try await $0.uninstall() }
    }

    private func changeCommandLine(_ change: (CommandLineInstaller) async throws -> Void) async {
        guard !isChangingCommandLine else { return }
        isChangingCommandLine = true
        defer {
            isChangingCommandLine = false
            commandLineState = commandLine.state()
        }
        do {
            try await change(commandLine)
            commandLineError = nil
        } catch CommandLineInstallError.cancelled {
            commandLineError = nil
        } catch {
            commandLineError = error.localizedDescription
        }
    }

    // MARK: Shared extensions

    /// Tells the collector which profile owns which config directory, so a session that runs another
    /// profile's status line command is still counted for its own profile (see `ProfileDirectories`).
    func writeProfileDirectories() throws {
        let map = ProfileDirectories(
            defaultProfile: profileStore.defaultProfile?.id,
            directories: Dictionary(profiles.map { (ProfileDirectories.canonical($0.configDir), $0.id) }, uniquingKeysWith: { first, _ in first })
        )
        try AtomicFile.write(UsageCoding.makeEncoder().encode(map), to: paths.pool.profileDirectories, permissions: 0o600)
    }

    /// Runs the shared-extensions sync off the main thread when the setting is on. A request while one
    /// is running queues exactly one more run.
    func syncSharedExtensions() {
        guard settings.shareExtensions, liveChecksEnabled else { return }
        guard sharedSyncTask == nil else { sharedSyncPending = true; return }
        let sync = SharedConfigSync(pool: paths.pool, home: paths.userHome)
        let profiles = profiles
        sharedSyncTask = Task { @MainActor [weak self] in
            let result = await Task.detached { Result { try sync.run(profiles: profiles) } }.value
            guard let self else { return }
            self.sharedSyncAt = Date()
            switch result {
            case let .success(report):
                if !report.changes.isEmpty { self.sharedSyncChanges = report.changes }
                self.sharedSyncError = nil
            case let .failure(error):
                self.sharedSyncError = error.localizedDescription
            }
            self.sharedSyncTask = nil
            if self.sharedSyncPending {
                self.sharedSyncPending = false
                self.syncSharedExtensions()
            }
        }
    }

    func setShareExtensions(_ enabled: Bool) {
        settings.shareExtensions = enabled
        if enabled { syncSharedExtensions() }
    }

    // MARK: Settings side effects

    func setCollectorOutput(_ mode: CollectorOutputMode) throws {
        settings.collectorOutput = mode
        try installer.writeOutputMode(mode)
    }

    // MARK: Diagnostics

    var diagnosticsNeedAttention: Bool {
        diagnostics.contains { $0.status == .warn || $0.status == .fail }
    }

    /// Number of warnings and failures, for the sidebar badge.
    var diagnosticsIssueCount: Int {
        diagnostics.filter { $0.status == .warn || $0.status == .fail }.count
    }

    func runDiagnostics() async {
        guard !isRunningDiagnostics else { return }
        isRunningDiagnostics = true
        defer { isRunningDiagnostics = false }
        refreshLocalState()
        async let functionProbe = diagnosticsService.probeShellFunction()
        async let variables = diagnosticsService.probeConflictingVariables()
        var pointerValue: String?
        var pointerError: String?
        do { pointerValue = try profileStore.pointer.read() } catch { pointerError = error.localizedDescription }
        let input = DiagnosticsInput(
            binary: await resolvedBinary(),
            shellStatus: shellStatus,
            shellFunctionProbe: await functionProbe,
            conflictingVariables: await variables,
            pointerValue: pointerValue,
            pointerError: pointerError,
            profiles: profiles,
            authStatuses: authStore.statuses,
            authErrors: authStore.errors,
            trackingStates: trackingStates,
            collectorState: collectorState,
            homePath: paths.userHome.path
        )
        diagnostics = DiagnosticsService.evaluate(input)
        diagnosticsRunAt = Date()
    }
}

struct TrackingRequest: Identifiable {
    let id = UUID()
    let profile: Profile
    let enable: Bool
    let preview: StatusLinePreview
}

/// Sidebar destinations of the manager window.
enum ManagerRoute: Hashable {
    case overview
    case sessions
    case analytics
    case statusline
    case mcp
    case profile(UUID)
    case diagnostics
    case settings
}

/// What a `claude` started now would use, as verified from disk and `claude auth status`.
enum LaunchReadiness: Equatable {
    case checking
    case ready(AuthStatus)
    case signedOut
    case overridden(String)
    case isolationBroken(String)
    case unverified(String)
    case pointerMismatch(String?)
    case pointerUnreadable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum AppModelError: Error, LocalizedError, Equatable {
    case binaryMissing
    case targetNotReady(String, String)
    case sessionGone
    case sessionBusy
    case folderMissing(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing: "Claude Code wasn't found. Install it, or set its path in Settings › Claude Code."
        case let .targetNotReady(name, reason): "“\(name)” can't take over this conversation because \(reason). Sign it in first, then try again."
        case .sessionGone: "That session has already ended."
        case .sessionBusy: "The session is working on a response. Wait until it is idle, or end it in its Terminal window."
        case let .folderMissing(folder): "\(folder) doesn't exist. Choose another folder."
        }
    }
}
