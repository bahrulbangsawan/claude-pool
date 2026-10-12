import Foundation
import Testing
@testable import ClaudePool

struct StatuslineRendererTests {
    private func values() -> StatuslineValues {
        var v = StatuslineValues(now: Date(timeIntervalSince1970: 1_790_990_000))
        v.model = "Opus"
        v.cwd = "/Users/x/claude-pool"
        v.gitBranch = "main"
        v.gitStatus = .init(staged: 1, modified: 2, untracked: 0, ahead: 3, behind: 0)
        v.contextPercent = 9.5
        v.contextTokens = 15_234
        v.contextSize = 200_000
        v.fiveHour = UsageWindow(usedPercentage: 23.4, resetsAt: Date(timeIntervalSince1970: 1_791_000_000))
        v.account = "me@example.com"
        v.plan = "Max 20x"
        return v
    }

    @Test func plainLayoutHidesMissingValuesAndSeparators() {
        var config = StatuslinePresets.essentials
        config.colorLevel = .truecolor
        let renderer = StatuslineRenderer(config: config)
        var v = values()
        v.gitBranch = nil
        let text = renderer.segments(values: v).map { $0.map(\.text).joined() }
        #expect(text == ["Opus │ claude-pool │ Ctx 10% │ 5h 23% │ me@example.com"])
    }

    @Test func widgetTexts() {
        let v = values()
        func t(_ kind: StatuslineWidgetKind, label: Bool = false) -> String? { StatuslineRenderer.text(for: StatuslineWidget(kind: kind, showLabel: label), values: v) }
        #expect(t(.gitStatus) == "+1 ~2 ↑3")
        #expect(t(.contextTokens) == "15.2k/200k")
        #expect(t(.fiveHourReset) == "2h 46m")
        #expect(t(.sevenDayUsage) == nil)
        #expect(t(.plan, label: true) == "Plan Max 20x")
        var expired = v
        expired.now = Date(timeIntervalSince1970: 1_791_000_001)
        // A window whose reset has passed shows nothing rather than a stale percentage.
        #expect(StatuslineRenderer.text(for: StatuslineWidget(kind: .fiveHourUsage), values: expired) == nil)
    }

    @Test func valuesCannotInjectEscapesOrLineBreaks() {
        var v = values()
        v.model = "Op\u{1B}[31mus\nX"
        let text = StatuslineRenderer.text(for: StatuslineWidget(kind: .model), values: v)
        #expect(text == "Op[31musX")
    }

    @Test func powerlineArrowsBridgeBackgrounds() {
        let config = StatuslineConfig(lines: [[StatuslineWidget(kind: .model), StatuslineWidget(kind: .cwd)]], theme: "ocean",
                                      powerline: PowerlineOptions(enabled: true))
        let segments = StatuslineRenderer(config: config).segments(values: values())[0]
        #expect(segments.map(\.text) == [" Opus ", "\u{E0B0}", " claude-pool ", "\u{E0B0}"])
        let theme = StatuslineTheme.named("ocean")!
        #expect(segments[1].foreground == theme.background[.model])
        #expect(segments[1].background == theme.background[.location])
        #expect(segments[3].background == nil)
    }

    @Test func flexSpacerAndAlignmentUseTheWidth() {
        let config = StatuslineConfig(lines: [[StatuslineWidget(kind: .model), StatuslineWidget(kind: .flexSpacer), StatuslineWidget(kind: .gitBranch)]])
        let line = StatuslineRenderer(config: config).segments(values: values(), width: 40)[0].map(\.text).joined()
        #expect(line.count == 36)
        #expect(line.hasPrefix("Opus ") && line.hasSuffix(" main"))
        // Without a known width the flexible space collapses to one space.
        #expect(StatuslineRenderer(config: config).segments(values: values())[0].map(\.text).joined() == "Opus main")
        var right = StatuslineConfig(lines: [[StatuslineWidget(kind: .model)]])
        right.alignment = .right
        #expect(StatuslineRenderer(config: right).segments(values: values(), width: 20)[0].map(\.text).joined() == String(repeating: " ", count: 12) + "Opus")
    }

    @Test func ansiColourLevels() {
        let segment = StatuslineSegment(text: "x", foreground: StatuslineColor("#FF8000"), background: StatuslineColor("blue"), bold: true)
        func ansi(_ level: StatuslineColorLevel) -> String {
            var config = StatuslinePresets.essentials
            config.colorLevel = level
            return StatuslineRenderer(config: config).ansi(segment)
        }
        #expect(ansi(.truecolor) == "\u{1B}[1;38;2;255;128;0;44mx\u{1B}[0m")
        #expect(ansi(.ansi256) == "\u{1B}[1;38;5;208;44mx\u{1B}[0m")
        #expect(ansi(.basic) == "\u{1B}[1;91;44mx\u{1B}[0m") // nearest of the 16: bright red
    }

    @Test func multilineAndEmptyLines() {
        let config = StatuslineConfig(lines: [[StatuslineWidget(kind: .model)], [StatuslineWidget(kind: .sevenDayUsage)], [StatuslineWidget(kind: .plan)]])
        #expect(StatuslineRenderer(config: config).segments(values: values()).count == 2)
        #expect(!StatuslineRenderer(config: config).ansi(values: values()).contains("\n\n"))
    }

    @Test func validationAndLossyDecoding() throws {
        var bad = StatuslinePresets.essentials
        bad.lines[0][0].foreground = StatuslineColor("not-a-colour")
        bad.padding = 9
        #expect(bad.validationErrors().count == 2)
        #expect(StatuslineConfig(lines: [[]]).validationErrors().contains("Add at least one component."))
        for preset in StatuslinePresets.all { #expect(preset.config.isValid, "\(preset.name)") }

        // A component kind from a newer version is dropped instead of failing the whole layout.
        let json = #"{"schema":1,"lines":[[{"id":"\#(UUID().uuidString)","kind":"model","bold":false,"showLabel":false},{"id":"\#(UUID().uuidString)","kind":"hologram","bold":false,"showLabel":false}]],"theme":"classic"}"#
        let decoded = try JSONDecoder().decode(StatuslineConfig.self, from: Data(json.utf8))
        #expect(decoded.lines[0].map(\.kind) == [.model])
        #expect(decoded.isValid)
    }
}

/// The collector binary in managed mode.
@Suite(.serialized) struct CollectorStatuslineTests {
    let temp: TempDirectory
    let pool: PoolPaths
    let binary: URL
    let profileID = UUID()

    init() throws {
        temp = try TempDirectory()
        pool = PoolPaths(home: temp.url.appendingPathComponent("pool", isDirectory: true))
        binary = try collectorBinary()
    }

    private func run(_ input: Data) throws -> ProcessOutput {
        try runProcess(binary, ["--profile", profileID.uuidString],
                       environment: [PoolPaths.homeOverrideVariable: pool.home.path, "PATH": "/usr/bin:/bin", "HOME": temp.url.path],
                       stdin: input)
    }

    @Test func managedProfileRendersTheAppliedLayout() throws {
        var config = StatuslineConfig(lines: [[StatuslineWidget(kind: .model), StatuslineWidget(kind: .plan), StatuslineWidget(kind: .contextPercent)]])
        config.colorLevel = .truecolor
        try StatuslineFiles.writeConfig(config, pool)
        try StatuslineFiles.writeProfile(StatuslineProfileState(managed: true, profileName: "Work", account: "me@work.example", plan: "Max 5x"), id: profileID, pool)
        let output = try run(Fixtures.data("statusline-full.json"))
        #expect(output.status == 0)
        let plain = output.stdoutText.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        #expect(plain == "Opus │ Max 5x │ 10%")

        // Rendering never persists display fields: the snapshot keeps only the schema keys.
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: pool.snapshot(for: profileID))) as? [String: Any])
        #expect(Set(raw.keys) == ["schema", "profileId", "observedAt", "lastSeenAt", "claudeVersion", "fiveHour", "sevenDay"])
        let stored = (readText(pool.snapshot(for: profileID)) ?? "") + (readText(pool.history(for: profileID)) ?? "")
        for forbidden in ["Opus", "secret-project", "cost", "context"] { #expect(!stored.contains(forbidden)) }
    }

    @Test func unmanagedOrInvalidFallsBackToSummary() throws {
        try StatuslineFiles.writeConfig(StatuslinePresets.essentials, pool)
        try StatuslineFiles.writeProfile(StatuslineProfileState(managed: false), id: profileID, pool)
        #expect(try run(Fixtures.data("statusline-full.json")).stdoutText == "5h 23% · 7d 41%")

        // Managed, but the config on disk is corrupt: never print garbage, fall back.
        try StatuslineFiles.writeProfile(StatuslineProfileState(managed: true), id: profileID, pool)
        try Data("{ not json".utf8).write(to: pool.statuslineConfig)
        #expect(try run(Fixtures.data("statusline-full.json")).stdoutText == "5h 23% · 7d 41%")
    }

    @Test func originalStatusLineCanBeEmbedded() throws {
        try AtomicFile.ensureDirectory(pool.chainDirectory)
        try Data("printf 'orig-line\\nsecond'".utf8).write(to: pool.chainCommand(for: profileID))
        try StatuslineFiles.writeConfig(StatuslineConfig(lines: [[StatuslineWidget(kind: .originalStatusLine), StatuslineWidget(kind: .model)]], colorLevel: .basic), pool)
        try StatuslineFiles.writeProfile(StatuslineProfileState(managed: true), id: profileID, pool)
        let plain = try run(Fixtures.data("statusline-full.json")).stdoutText
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        #expect(plain == "orig-line │ Opus")
    }

    @Test func gitBranchFromTheWorkingDirectory() throws {
        let repo = temp.file("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        _ = try runProcess(git, ["-C", repo.path, "init", "-q", "-b", "feature-x"], environment: ["HOME": temp.url.path, "PATH": "/usr/bin:/bin"])
        try Data("hi".utf8).write(to: repo.appendingPathComponent("new.txt"))
        try StatuslineFiles.writeConfig(StatuslineConfig(lines: [[StatuslineWidget(kind: .gitBranch), StatuslineWidget(kind: .gitStatus)]], colorLevel: .basic), pool)
        try StatuslineFiles.writeProfile(StatuslineProfileState(managed: true), id: profileID, pool)
        let payload = #"{"cwd":"\#(repo.path)","workspace":{"current_dir":"\#(repo.path)"},"model":{"display_name":"Opus"}}"#
        let plain = try run(Data(payload.utf8)).stdoutText.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        #expect(plain == "feature-x │ ?1")
    }
}
