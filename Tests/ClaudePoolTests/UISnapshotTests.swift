import AppKit
import SwiftUI
import Testing
@testable import ClaudePool

/// Renders every screen with sample data covering each usage state, in light and dark, by
/// hosting the real views in real windows and capturing them with `screencapture -l`.
/// Run with `make snapshots`; skipped in `make test`. Uses a temp home; touches nothing real.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLAUDE_POOL_SNAPSHOT_DIR"] != nil))
struct UISnapshotTests {
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_POOL_SNAPSHOT_DIR"] ?? "/tmp")

    @Test func renderAllScreens() async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let temp = try TempDirectory()
        let model = try SampleData.model(temp: temp)
        try await SampleData.addLiveSamples(model, temp: temp)
        // Read-only: use the real claude binary (the temp home has none) and run the shell probes.
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        model.settings.claudePathOverride = [".local/bin/claude", ".claude/local/claude"].map { realHome.appendingPathComponent($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        await model.locateBinary()
        await model.runDiagnostics()
        app.activate(ignoringOtherApps: true)
        // Two real CPU/memory samples, including the sample sessions' processes.
        model.resourceStore.start { [sessions = model.sessionStore.sessions] in sessions.map(\.pid) }
        model.resourceStore.stop()
        try await Task.sleep(for: .milliseconds(500))
        model.resourceStore.sample()

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await capture(MenuBarView(), model: model, name: "menu-\(suffix)", size: NSSize(width: 340, height: 620), dark: dark, panel: true)
            for (route, name) in SampleData.routes(model) {
                model.route = route
                try await capture(ManagerWindow(), model: model, name: "\(name)-\(suffix)", size: NSSize(width: 1100, height: 760), dark: dark)
            }
        }
        // Menu bar label: brand mark, name, 5h/7d usage, CPU/MEM.
        for dark in [false, true] {
            try await capture(MenuBarLabel(model: model).padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading),
                              model: model, name: "menubar-label-\(dark ? "dark" : "light")", size: NSSize(width: 420, height: 34), dark: dark, panel: true)
        }
        // Opt-in suggestion: Personal (93% of its 5-hour window) active, Work has the most room.
        let previousActive = model.profileStore.activeProfile
        model.settings.suggestAccountEnabled = true
        model.setActive(model.profiles[2])
        try await capture(MenuBarView(), model: model, name: "menu-suggestion-light", size: NSSize(width: 340, height: 660), dark: false, panel: true)
        try await capture(MenuBarView(), model: model, name: "menu-suggestion-dark", size: NSSize(width: 340, height: 660), dark: true, panel: true)
        model.settings.suggestAccountEnabled = false
        if let previousActive { model.setActive(previousActive) }
        // Narrowest supported window, light only.
        model.route = .overview
        try await capture(ManagerWindow(), model: model, name: "overview-min", size: NSSize(width: 900, height: 560), dark: false)
        let chart = UsageHistoryChart(profileID: model.profiles[1].id, previewHoverDate: Date().addingTimeInterval(-3 * 3_600))
            .padding(Space.lg)
        try await capture(chart, model: model, name: "chart-hover-light", size: NSSize(width: 860, height: 520), dark: false, panel: true)
        try await capture(chart, model: model, name: "chart-hover-dark", size: NSSize(width: 860, height: 520), dark: true, panel: true)
        let preview = try model.previewEnableTracking(model.profiles[0])
        try await capture(TrackingConfirmSheet(request: TrackingRequest(profile: model.profiles[0], enable: true, preview: preview)),
                          model: model, name: "sheet-tracking", size: NSSize(width: 600, height: 460), dark: false, panel: true)
        try await capture(AddAccountSheet(), model: model, name: "sheet-add-account", size: NSSize(width: 520, height: 480), dark: false, panel: true)
        // In-app sign-in, waiting for authorization (driven by a stand-in claude; see LoginFlowTests).
        let fake = temp.file("fake-bin/claude")
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(LoginFlowTests.fakeClaude.utf8).write(to: fake)
        chmod(fake.path, 0o755)
        let personal = model.profiles[2]
        let flow = LoginFlow(profile: personal, binary: ClaudeBinary(path: fake.path, source: .userOverride, version: "test"),
                             paths: model.paths, previousIdentity: nil) { _ in nil }
        model.loginFlow = flow
        flow.start(emailHint: nil)
        for _ in 0..<40 where flow.phase != .waitingForAuthorization || flow.callbackURL == nil { try await Task.sleep(for: .milliseconds(100)) }
        try await capture(SignInSheet(profile: personal), model: model, name: "sheet-signin", size: NSSize(width: 600, height: 520), dark: false, panel: true)
        try await capture(SignInSheet(profile: personal), model: model, name: "sheet-signin-dark", size: NSSize(width: 600, height: 520), dark: true, panel: true)
        flow.cancel()
        if let session = model.sessionStore.sessions.first(where: { $0.profileID == model.profiles[0].id }) {
            try await capture(HandoffSheet(request: HandoffRequest(session: session, target: model.profiles[1])), model: model,
                              name: "sheet-handoff", size: NSSize(width: 540, height: 480), dark: false, panel: true)
        }
    }

    private func capture<V: View>(_ view: V, model: AppModel, name: String, size: NSSize, dark: Bool, panel: Bool = false) async throws {
        let controller = NSHostingController(rootView: view.environment(model))
        let style: NSWindow.StyleMask = panel ? [.titled, .fullSizeContentView] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size), styleMask: style, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        window.title = "Claude Pool"
        if panel { window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(1200))
        let file = out.appendingPathComponent("\(name).png").path
        let result = try runProcess(URL(fileURLWithPath: "/usr/sbin/screencapture"), ["-x", "-o", "-l\(window.windowNumber)", file], environment: [:])
        #expect(result.status == 0, "screencapture failed for \(name)")
        window.orderOut(nil)
    }
}

/// Five profiles, one per interesting state, plus history for the charts.
@MainActor
enum SampleData {
    static func routes(_ model: AppModel) -> [(ManagerRoute, String)] {
        [
            (.overview, "overview"),
            (.sessions, "sessions"),
            (.analytics, "analytics"),
            (.statusline, "statusline"),
            (.profile(model.profiles[1].id), "profile-work"),
            (.profile(model.profiles[3].id), "profile-client"),
            (.diagnostics, "diagnostics"),
            (.settings, "settings"),
        ]
    }

    static func model(temp: TempDirectory) throws -> AppModel {
        let paths = temp.paths
        try FileManager.default.createDirectory(at: paths.defaultConfigDir, withIntermediateDirectories: true)
        let model = AppModel(paths: paths, loginShell: "/bin/zsh", bundledHelper: try collectorBinary())
        model.liveChecksEnabled = false
        model.settingsStore.load()
        model.profileStore.load()
        let store = model.profileStore
        let work = try store.add(name: "Work", slug: "work", configDir: paths.userHome.appendingPathComponent(".claude-work").path)
        let personal = try store.add(name: "Personal", slug: "personal", configDir: paths.userHome.appendingPathComponent(".claude-personal").path)
        let client = try store.add(name: "Client — Northwind", slug: "client", configDir: paths.userHome.appendingPathComponent(".claude-client").path)
        let api = try store.add(name: "API key", slug: "api", configDir: paths.userHome.appendingPathComponent(".claude-api").path)
        let defaultID = store.defaultProfile!.id
        for profile in store.profiles {
            var p = profile
            p.trackingEnabled = profile.id != api.id
            try store.update(p)
            if p.trackingEnabled { _ = try? model.patcher.enable(p, collectorPath: model.collectorPath) }
        }
        store.setActive(work.id)

        let now = Date()
        try AtomicFile.ensureDirectory(paths.pool.usageDirectory)
        func snap(_ id: UUID, ago: TimeInterval, fh: Double?, fhIn: TimeInterval, sd: Double?, sdIn: TimeInterval) throws {
            let s = UsageSnapshot(
                profileId: id, observedAt: now.addingTimeInterval(-ago), lastSeenAt: now, claudeVersion: "2.1.296",
                fiveHour: fh.map { UsageWindow(usedPercentage: $0, resetsAt: now.addingTimeInterval(fhIn)) },
                sevenDay: sd.map { UsageWindow(usedPercentage: $0, resetsAt: now.addingTimeInterval(sdIn)) }
            )
            try AtomicFile.write(UsageCoding.makeEncoder().encode(s), to: paths.pool.snapshot(for: id))
        }
        try snap(defaultID, ago: 30, fh: 74, fhIn: 6_600, sd: 100, sdIn: -5_700)
        try snap(work.id, ago: 120, fh: 23, fhIn: 8_000, sd: 41, sdIn: 3 * 86_400 + 4 * 3_600)
        try snap(personal.id, ago: 40 * 60, fh: 93, fhIn: 1_500, sd: 68, sdIn: 5 * 86_400)

        // Seven days of history for Work: 5h climbs and resets every 5h; 7d climbs slowly.
        var lines = Data()
        let encoder = UsageCoding.makeEncoder()
        var t = now.addingTimeInterval(-7 * 86_400)
        let fiveHours: TimeInterval = 5 * 3_600
        while t < now {
            let windowStart = floor(t.timeIntervalSince1970 / fiveHours) * fiveHours
            let into = (t.timeIntervalSince1970 - windowStart) / fiveHours
            let day = Calendar.current.component(.hour, from: t)
            let active = (9...19).contains(day)
            let fh = active ? min(100, into * 85 + 5) : into * 10
            let weekStart = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
            let sd = min(100, (t.timeIntervalSince1970 - weekStart) / (7 * 86_400) * 45)
            let entry = UsageHistoryEntry(t: t.timeIntervalSince1970.rounded(), fh: fh.rounded(), fhr: windowStart + fiveHours,
                                          sd: sd.rounded(), sdr: now.addingTimeInterval(3 * 86_400 + 4 * 3_600).timeIntervalSince1970.rounded())
            lines.append(try encoder.encode(entry))
            lines.append(10)
            t = t.addingTimeInterval(active ? 25 * 60 : 90 * 60)
        }
        try lines.write(to: paths.pool.history(for: work.id))
        model.usageStore.reload()

        func auth(_ signedIn: Bool, _ method: String, _ identity: String?, _ plan: String?, dir: String? = nil, email: String? = nil) -> AuthStatus {
            AuthStatus(signedIn: signedIn, authMethod: method, configDirectory: dir, identityLabel: identity, subscriptionType: plan,
                       checkedAt: now.addingTimeInterval(-180), email: email)
        }
        model.authStore.record(auth(true, "claude.ai", "me@company.example · Company", "team", dir: paths.defaultConfigDir.path, email: "me@company.example"), for: defaultID)
        model.authStore.record(auth(true, "claude.ai", "me@work.example · Work Org", "max", dir: work.configDir, email: "me@work.example"), for: work.id)
        model.authStore.record(auth(true, "claude.ai", "me@home.example", "pro", dir: personal.configDir, email: "me@home.example"), for: personal.id)
        // Plan details as Claude Code caches them in .claude.json (non-secret oauthAccount fields).
        try Data(#"{"oauthAccount":{"emailAddress":"me@work.example","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"}}"#.utf8)
            .write(to: URL(fileURLWithPath: work.configDir).appendingPathComponent(".claude.json"))
        try Data(#"{"oauthAccount":{"emailAddress":"me@company.example","organizationType":"claude_team","seatTier":"premium"}}"#.utf8)
            .write(to: paths.userHome.appendingPathComponent(".claude.json"))
        model.authStore.reloadDetails(model.profiles)
        model.authStore.record(auth(false, "none", nil, nil, dir: client.configDir), for: client.id)
        model.authStore.record(auth(true, "api_key", nil, nil, dir: api.configDir), for: api.id)
        model.refreshLocalState()
        return model
    }
}

extension SampleData {
    /// Running sessions (this test process stands in for claude), 30 days of conversation records,
    /// and a managed status line, all inside the temp home.
    static func addLiveSamples(_ model: AppModel, temp: TempDirectory) async throws {
        let profiles = model.profiles
        let defaultProfile = profiles[0], work = profiles[1], personal = profiles[2]
        let pid = getpid()
        let start = SessionRegistryService.liveStartTime(pid) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        func register(_ profile: Profile, pid: Int32, cwd: String, name: String, status: String, start: Date = start) throws {
            let dir = SessionRegistryService.directory(for: profile)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = #"{"pid":\#(pid),"sessionId":"\#(UUID().uuidString)","cwd":"\#(cwd)","name":"\#(name)","startedAt":\#(start.timeIntervalSince1970 * 1000 + 1000),"updatedAt":\#(Date().timeIntervalSince1970 * 1000),"status":"\#(status)","version":"2.1.296","kind":"interactive","procStart":"\#(formatter.string(from: start))"}"#
            try Data(json.utf8).write(to: dir.appendingPathComponent("\(pid).json"))
        }
        let home = model.paths.userHome.path
        try register(defaultProfile, pid: pid, cwd: "\(home)/projects/billing-service", name: "billing-service", status: "idle")
        try register(work, pid: getppid(), cwd: "\(home)/projects/claude-pool", name: "claude-pool", status: "busy",
                     start: SessionRegistryService.liveStartTime(getppid()) ?? start)
        model.sessionStore.start { model.profiles }
        model.sessionStore.stop()

        // Conversation records: a few requests per hour of the working day for 40 days.
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (profile, scale, models) in [(work, 1.0, ["claude-opus-5-5", "claude-sonnet-5-5"]), (defaultProfile, 0.6, ["claude-opus-5-5"]),
                                         (personal, 0.3, ["claude-haiku-5-5", "claude-sonnet-5-5"])] {
            let dir = URL(fileURLWithPath: profile.configDir).appendingPathComponent("projects/-sample")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines: [String] = []
            var t = now.addingTimeInterval(-40 * 86_400)
            var n = 0
            while t < now {
                let hour = Calendar.current.component(.hour, from: t)
                let weekday = Calendar.current.component(.weekday, from: t)
                if (9...19).contains(hour), weekday != 1, weekday != 7 || n % 3 == 0 {
                    let wave = 0.6 + 0.4 * sin(t.timeIntervalSince1970 / 86_400)
                    let model = models[n % models.count]
                    lines.append(UsageIndexTests.line(msg: "m\(n)", req: "r\(n)", at: iso.string(from: t), model: model,
                                                      input: Int(400 * scale * wave), output: Int(9_000 * scale * wave),
                                                      read: Int(450_000 * scale * wave), write: Int(30_000 * scale * wave)))
                    n += 1
                }
                t = t.addingTimeInterval(Double(900 + (n % 5) * 600))
            }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).jsonl"))
        }
        model.analyticsStore.start { model.profiles }
        for _ in 0..<100 {
            if model.analyticsStore.lastIndexedAt != nil, model.analyticsStore.report?.current.requests ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        // Status line: the detailed preset applied and shown for Work.
        model.statuslineStore.load(profiles: profiles)
        model.statuslineStore.draft = StatuslinePresets.detailed
        try model.statuslineStore.apply()
        try model.statuslineStore.setManaged(true, for: work, account: "me@work.example", plan: "Max 20x")
        model.refreshLocalState()
    }
}
