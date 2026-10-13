import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingInstall = false
    @State private var confirmingUninstall = false
    @State private var shellMessage: String?
    @State private var shellError: String?
    @State private var overridePath = ""
    @State private var loginItemEnabled = false
    @State private var loginItemStatus = ""
    @State private var settingsError: String?

    var body: some View {
        @Bindable var settingsStore = model.settingsStore
        Page {
            PageHeader(title: "Settings")
        } content: {
            if let error = settingsError ?? model.settingsStore.lastError {
                InlineMessage(kind: .error, text: error) {
                    settingsError = nil
                    model.settingsStore.lastError = nil
                }
            }
            shellCard
            binaryCard

            Card(title: "Terminal") {
                SettingRow(title: "Working directory", detail: "New Terminal windows start here, then run claude with the profile.") {
                    HStack(spacing: Space.xs) {
                        TextField("Working directory", text: $settingsStore.settings.defaultWorkingDirectory)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(width: 200)
                        Button("Choose…") {
                            if let url = Panels.chooseDirectory(startingAt: model.paths.expandTilde(model.settings.defaultWorkingDirectory)) {
                                model.settings.defaultWorkingDirectory = model.paths.abbreviate(url.path)
                            }
                        }
                    }
                }
            }

            Card(title: "Menu Bar") {
                VStack(spacing: Space.xs) {
                    SettingRow(title: "Show active profile name") {
                        Toggle("Show active profile name", isOn: $settingsStore.settings.showNameInMenuBar).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    SettingRow(title: "Show active usage limits", detail: "5h:23% · 7d:41%, from the last reported values. – means that window has no value yet.") {
                        Toggle("Show active usage limits", isOn: $settingsStore.settings.showActiveUsageInMenuBar).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    SettingRow(title: "Show CPU and memory", detail: "This Mac's CPU and memory use, updated every \(Int(ResourceStore.interval)) seconds.") {
                        Toggle("Show CPU and memory", isOn: $settingsStore.settings.showSystemStatsInMenuBar).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            alertsCard

            Card(title: "Status Line") {
                SettingRow(title: "When a profile had no status line",
                           detail: "Profiles that already had a status line keep showing it; the collector passes its output through.") {
                    Picker("When a profile had no status line", selection: Binding(
                        get: { model.settings.collectorOutput },
                        set: { mode in
                            do { try model.setCollectorOutput(mode); settingsError = nil }
                            catch { settingsError = "Couldn't save the status line setting: \(error.localizedDescription). Check that ~/.claude-pool is writable." }
                        }
                    )) {
                        Text("Show usage summary").tag(CollectorOutputMode.summary)
                        Text("Show nothing").tag(CollectorOutputMode.none)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Card(title: "Startup") {
                SettingRow(title: "Open at login", detail: loginItemStatus) {
                    Toggle("Open at login", isOn: Binding(
                        get: { loginItemEnabled },
                        set: { enabled in
                            do { try model.loginItem.setEnabled(enabled); settingsError = nil }
                            catch { settingsError = "Couldn't change Open at login: \(error.localizedDescription). Move Claude Pool to Applications and try again." }
                            readLoginItem()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            aboutCard
        }
        .onAppear {
            overridePath = model.settings.claudePathOverride ?? ""
            readLoginItem()
            model.refreshLocalState()
        }
        .sheet(isPresented: $showingInstall) { installSheet }
        .confirmationDialog("Remove the Claude Pool block from \(targetDisplay)?", isPresented: $confirmingUninstall) {
            Button("Remove Block", role: .destructive) {
                do {
                    let backup = try model.uninstallShellIntegration()
                    shellError = nil
                    shellMessage = backup.map { "Removed. Backup saved to \(model.paths.abbreviate($0.path))." } ?? "There was no block to remove."
                } catch {
                    shellError = "\(error.localizedDescription) The file wasn't changed."
                }
            }
        } message: {
            Text("Only the lines between the claude-pool markers are removed. A backup is saved first.")
        }
    }

    // MARK: Shell integration

    private var targetDisplay: String {
        model.shell.targetFile.map { model.paths.abbreviate($0.path) } ?? "your shell startup file"
    }

    private var shellCard: some View {
        let status = model.shellStatus
        return Card(title: "Shell Integration", subtitle: "A plain claude in new terminals uses the active profile. An explicit CLAUDE_CONFIG_DIR=… claude always wins.") {
            switch status {
            case .installed: StatusBadge(text: "Installed", systemImage: "checkmark.circle.fill", tint: .statusOK)
            case .outdated: StatusBadge(text: "Outdated", systemImage: "arrow.triangle.2.circlepath", tint: .statusWarn)
            case .notInstalled: StatusBadge(text: "Not Installed", systemImage: "minus.circle", tint: .statusWarn)
            case .unsupportedShell: StatusBadge(text: "Manual Setup", systemImage: "hand.raised", tint: .secondary)
            }
        } content: {
            FactRow(label: "File") { Text(targetDisplay).font(.rowDetail.monospaced()) }
            if case let .unsupportedShell(shell) = status {
                InlineMessage(kind: .info, text: "Your login shell is \(shell). Copy the snippet into its startup file.")
            }
            HStack(spacing: Space.xs) {
                Button(status == .installed ? "Reinstall…" : (status == .outdated ? "Update…" : "Install…")) { showingInstall = true }
                    .disabled(model.shell.targetFile == nil)
                Button("Remove…") { confirmingUninstall = true }
                    .disabled(model.shell.targetFile == nil || status == .notInstalled)
                Button("Copy Snippet") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ShellIntegrationService.snippet, forType: .string)
                    shellMessage = "Snippet copied to the clipboard."
                }
                Spacer()
            }
            if let shellMessage { Text(shellMessage).font(.meta).foregroundStyle(.secondary) }
            if let shellError { InlineMessage(kind: .error, text: shellError) { self.shellError = nil } }
        }
    }

    private var installSheet: some View {
        SheetScaffold(
            title: "Install Shell Integration",
            subtitle: "This block is added to \(targetDisplay), or replaces an existing Claude Pool block. The file is backed up first.",
            width: 600
        ) {
            ScrollView {
                Text(ShellIntegrationService.snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.sm)
            }
            .frame(height: 220)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            Text("Open a new terminal window afterwards. Running sessions keep their account.")
                .font(.meta)
                .foregroundStyle(.secondary)
        } buttons: {
            Button("Cancel", role: .cancel) { showingInstall = false }
                .keyboardShortcut(.cancelAction)
            Button("Install") {
                do {
                    let backup = try model.installShellIntegration()
                    shellError = nil
                    shellMessage = "Installed." + (backup.map { " Backup saved to \(model.paths.abbreviate($0.path))." } ?? "")
                } catch {
                    shellError = "\(error.localizedDescription) Use Copy Snippet to add it by hand."
                }
                showingInstall = false
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Limit alerts

    private var alertsCard: some View {
        @Bindable var settingsStore = model.settingsStore
        return Card(title: "Limit Alerts", subtitle: "Off by default. They only inform you; Claude Pool never switches accounts on its own.") {
            VStack(spacing: Space.xs) {
                SettingRow(title: "Notify near and at a limit",
                           detail: "One notification when a 5-hour or 7-day window reaches the threshold, and one when it reaches 100%, for each reset period.") {
                    Toggle("Notify near and at a limit", isOn: Binding(
                        get: { model.settings.limitAlertsEnabled },
                        set: { enabled in Task { await model.setLimitAlerts(enabled) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                if model.settings.limitAlertsEnabled {
                    notificationStatus
                }
                Divider()
                SettingRow(title: "Threshold", detail: "Also used for the suggestion below.") {
                    Picker("Threshold", selection: $settingsStore.settings.limitAlertThreshold) {
                        ForEach([75, 80, 85, 90, 95], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                SettingRow(title: "Suggest the account with the most room",
                           detail: "When the active account reaches the threshold or a limit, the menu names the signed-in account with the lowest reported usage. You choose whether to switch.") {
                    Toggle("Suggest the account with the most room", isOn: $settingsStore.settings.suggestAccountEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .task { await model.refreshNotificationAuthorization() }
    }

    @ViewBuilder
    private var notificationStatus: some View {
        switch model.notificationAuthorization {
        case .allowed:
            EmptyView()
        case .notDetermined:
            InlineMessage(kind: .info, text: "Claude Pool needs permission to post notifications.") {
                Button("Allow…") { Task { await model.setLimitAlerts(true) } }.controlSize(.small)
            }
        case .denied:
            InlineMessage(kind: .warning, text: "Notifications are turned off for Claude Pool in System Settings › Notifications.") {
                Button("Open…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
        case .unavailable:
            InlineMessage(kind: .info, text: "Notifications need Claude Pool to run as an app (build/ClaudePool.app).")
        }
    }

    // MARK: Binary

    private var binaryCard: some View {
        Card(title: "Claude Code") {
            if model.isLocatingBinary {
                ProgressView().controlSize(.small)
            } else if model.binary != nil {
                StatusBadge(text: "Found", systemImage: "checkmark.circle.fill", tint: .statusOK)
            } else {
                StatusBadge(text: "Not Found", systemImage: "xmark.octagon.fill", tint: .statusFail)
            }
        } content: {
            VStack(spacing: Space.xs) {
                FactRow(label: "Path") {
                    Text(model.binary.map { model.paths.abbreviate($0.path) } ?? "—").font(.rowDetail.monospaced()).textSelection(.enabled)
                }
                Divider()
                FactRow(label: "Version") { Text(model.binary?.version ?? "—") }
                Divider()
                FactRow(label: "Found via") { Text(model.binary?.source.rawValue ?? "—") }
                Divider()
                SettingRow(title: "Custom path", detail: "Leave empty to find claude through your login shell.") {
                    HStack(spacing: Space.xs) {
                        TextField("Custom path", text: $overridePath, prompt: Text("~/.local/bin/claude"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(width: 220)
                            .onSubmit(applyOverride)
                        Button("Choose…") {
                            if let url = Panels.chooseExecutable(startingAt: model.binary?.path) {
                                overridePath = url.path
                                applyOverride()
                            }
                        }
                        Button("Apply", action: applyOverride)
                    }
                }
            }
        }
    }

    private func applyOverride() {
        let trimmed = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !FileManager.default.isExecutableFile(atPath: model.paths.expandTilde(trimmed)) {
            settingsError = "\(trimmed) isn't an executable file. Choose the claude binary itself, for example ~/.local/bin/claude."
            return
        }
        settingsError = nil
        model.settings.claudePathOverride = trimmed.isEmpty ? nil : trimmed
        Task { await model.locateBinary() }
    }

    private func readLoginItem() {
        loginItemEnabled = model.loginItem.isEnabled
        loginItemStatus = model.loginItem.statusDescription
    }

    // MARK: About

    /// "Version 1.1.0 (2)" from the bundle; unbundled runs have no Info.plist values.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return (info?["CFBundleVersion"] as? String).map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    private var aboutCard: some View {
        Card(title: "About") {
            HStack(spacing: Space.sm) {
                AppIconView(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Pool").font(.sectionTitle)
                    Text(Self.appVersion).font(.meta.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Text("Claude Pool is an unofficial utility for switching between separately signed-in Claude Code accounts. It doesn't pool, combine or rotate usage limits, and it never switches for you.")
                .font(.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Compliance") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Data sources (exactly two)").font(.rowDetail.weight(.semibold))
                    Text("1. The status line JSON Claude Code sends to the collector. Only rate_limits.five_hour, rate_limits.seven_day and version are decoded.")
                    Text("2. The output of the unmodified claude auth status. Only sign-in state, auth method, config directory and display-only identity fields are kept, in memory.")
                    Text("Never done").font(.rowDetail.weight(.semibold)).padding(.top, Space.xxs)
                    Text("• Reading, copying, showing or logging credentials, tokens, sign-in files or Keychain items.")
                    Text("• Any network access, including usage or sign-in endpoints, scraping or proxying.")
                    Text("• Reading session history, prompts or any file in a profile directory, except the statusLine key of settings.json after you opt in.")
                    Text("• Switching automatically (by usage, limits, errors, timers or heuristics), rotating or load-balancing accounts, or forecasting usage. The opt-in limit alerts and suggestion only inform you; every switch is your click.")
                    Text("• Modifying the claude binary or signing in on your behalf.")
                }
                .font(.rowDetail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xs)
            }
        }
    }
}
