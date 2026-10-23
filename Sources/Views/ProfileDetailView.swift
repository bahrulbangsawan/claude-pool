import SwiftUI

/// One profile: usage, history, sign-in, tracking, then its settings.
struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let onRemove: () -> Void
    @State private var name = ""
    @State private var basicsError: String?
    @State private var actionError: String?
    @State private var signInHint = false

    private var current: Profile { model.profileStore.profile(id: profile.id) ?? profile }
    private var isActive: Bool { model.profileStore.activeProfileID == profile.id }

    var body: some View {
        Page {
            header
        } content: {
            if let actionError {
                InlineMessage(kind: .error, text: actionError) { self.actionError = nil }
            }
            if isActive {
                Card(title: "New launches") {
                    LaunchReadinessLine(profile: current)
                    ShellCoverageNote()
                }
            }
            usageCard
            sessionsCard
            UsageHistoryChart(profileID: current.id)
            signInCard
            trackingCard
            profileCard
            removeCard
        }
        .onAppear { name = current.name }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            ProfileAvatar(name: current.name, colorHex: current.colorHex, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xs) {
                    Text(current.name).font(.pageTitle).lineLimit(1).help(current.name).accessibilityAddTraits(.isHeader)
                    if isActive { StatusBadge(text: "Active", systemImage: "checkmark.circle.fill", tint: .accentColor) }
                    if current.isDefault { StatusBadge(text: "Default", systemImage: "house", tint: .secondary) }
                    if let plan = model.authStore.plan(for: current.id) { PlanBadge(plan: plan) }
                }
                PathText(path: current.configDir, paths: model.paths, font: .rowDetail)
            }
            Spacer(minLength: Space.md)
            Button("Set Active") { model.setActive(current) }
                .disabled(isActive)
            Button {
                launch(signIn: false)
            } label: {
                Label("Open Terminal", systemImage: "terminal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.binary == nil)
        }
    }

    // MARK: Usage

    private var usageCard: some View {
        let five = model.usageState(current, .fiveHour)
        let seven = model.usageState(current, .sevenDay)
        return Card(title: "Usage") {
            if let snapshot = model.usageStore.snapshot(for: current.id), let observed = snapshot.observedAt,
               five.displayedWindow != nil || seven.displayedWindow != nil {
                ObservationLabel(observedAt: observed, stale: five.isStale || seven.isStale, formatting: model.formatting)
            }
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.lg) {
                    UsageRing(kind: .fiveHour, state: five, formatting: model.formatting)
                    UsageRing(kind: .sevenDay, state: seven, formatting: model.formatting)
                }
                VStack(alignment: .leading, spacing: Space.md) {
                    UsageRing(kind: .fiveHour, state: five, formatting: model.formatting)
                    UsageRing(kind: .sevenDay, state: seven, formatting: model.formatting)
                }
            }
            AvailabilityBadge(availability: model.availability(current), formatting: model.formatting)
            CheckUsageButton(profile: current, labelled: true) { actionError = $0 }
            if five == .trackingOff {
                Button("Enable Usage Tracking…") { model.requestTrackingChange(current, enable: true) }
            } else if five == .signedOut {
                Button("Sign In…") { model.signInRequest = current }
            } else if five == .noData {
                Text("Claude Code reports the windows in its status line once a session with this profile gets its first response. Claude Pool doesn't contact Anthropic itself; Check Usage Now has Claude Code send one tiny request instead.")
                    .font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if five.isStale || seven.isStale {
                Text(UsageFormatting.staleFootnote).font(.meta).foregroundStyle(.secondary)
            }
            Text("Source: Claude Code status line on this Mac. Values are as reported by Claude Code at the time shown.")
                .font(.meta)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Sign-in

    private var signInCard: some View {
        let status = model.authStore.status(for: current.id)
        return Card(title: "Sign-In", subtitle: status.map { "Checked \(model.formatting.age(since: $0.checkedAt))" }) {
            Button {
                Task { await model.refreshAuth(current) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: Metrics.minHitTarget, height: Metrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.authStore.refreshing.contains(current.id))
            .help("Refresh sign-in status")
            .accessibilityLabel("Refresh sign-in status")
        } content: {
            VStack(spacing: Space.xs) {
                FactRow(label: "Status") { SignInLine(profile: current) }
                if let status {
                    Divider()
                    FactRow(label: "Method") { Text(status.authMethodLabel) }
                    if let identity = status.identityLabel {
                        Divider()
                        FactRow(label: "Account") { Text(identity).textSelection(.enabled) }
                    }
                    if let plan = model.authStore.plan(for: current.id) {
                        Divider()
                        FactRow(label: "Plan") { PlanBadge(plan: plan) }
                    } else if let raw = status.subscriptionType {
                        Divider()
                        FactRow(label: "Plan") { Text(raw.capitalized) }
                    }
                    if let details = model.authStore.details[current.id], let fetched = details.profileFetchedAt {
                        Divider()
                        FactRow(label: "Account data") { Text("refreshed by Claude Code \(model.formatting.age(since: fetched))") }
                    }
                    if let reported = status.configDirectory {
                        Divider()
                        let isolated = Paths.canonical(reported) == Paths.canonical(current.configDir)
                        FactRow(label: "Isolation") {
                            Label(isolated ? "Uses this profile's directory" : "Uses \(reported)",
                                  systemImage: isolated ? "checkmark.shield" : "exclamationmark.triangle.fill")
                                .foregroundStyle(isolated ? Color.secondary : Color.statusFail)
                                .help(reported)
                        }
                    }
                }
            }
            AccountMismatchNote(profile: current)
            if let status, status.signedIn, !status.reportsUsage {
                InlineMessage(kind: .warning, text: "This profile is signed in with \(status.authMethodLabel), which overrides the subscription sign-in, so usage isn't reported. Remove the exported key or apiKeyHelper, then run /login.")
            }
            HStack(spacing: Space.xs) {
                Button("Sign In…") { model.signInRequest = current }
                    .disabled(model.binary == nil)
                    .help("Sign in without Terminal, using Claude Code's own sign-in")
                Button("Sign In with Terminal") { launch(signIn: true) }
                    .disabled(model.binary == nil)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([current.configURL]) }
                    .disabled(!FileManager.default.fileExists(atPath: current.configDir))
            }
            if signInHint {
                InlineMessage(kind: .info, text: "In the new Terminal window, run /login to sign in the first time, or /status to check the account. This page re-checks in about 30 seconds.")
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionsCard: some View {
        let sessions = model.sessionStore.sessions(for: current.id)
        if !sessions.isEmpty {
            Card(title: "Running sessions", subtitle: "These keep this profile's account until they exit") {
                Button("Manage…") { model.route = .sessions }.controlSize(.small)
            } content: {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(sessions) { session in
                        HStack(spacing: Space.xs) {
                            Image(systemName: session.isBusy ? "bolt.circle.fill" : "moon.circle")
                                .foregroundStyle(session.isBusy ? Color.accentColor : Color.secondary).accessibilityHidden(true)
                            Text(session.name ?? session.folderName).font(.rowDetail)
                            PathText(path: session.cwd, paths: model.paths)
                            Spacer()
                            Text(session.status ?? "").font(.meta).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Tracking

    private var trackingCard: some View {
        let state = model.trackingState(for: current)
        return Card(title: "Usage Tracking") {
            SettingRow(title: "Collect usage from the status line",
                       detail: "Points this profile's statusLine at the Claude Pool collector, after you confirm the change.") {
                Toggle("Collect usage from the status line", isOn: Binding(
                    get: { current.trackingEnabled },
                    set: { model.requestTrackingChange(current, enable: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            if state == .overridden {
                InlineMessage(kind: .warning, text: "statusLine was changed outside Claude Pool (for example with /statusline), so usage is no longer collected.") {
                    Button("Re-enable…") { model.requestTrackingChange(current, enable: true) }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Profile settings

    private var profileCard: some View {
        Card(title: "Profile") {
            VStack(spacing: Space.xs) {
                SettingRow(title: "Name") {
                    TextField("Name", text: $name)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit(saveName)
                }
                Divider()
                SettingRow(title: "Color") {
                    ColorSwatchPicker(selection: Binding(get: { current.colorHex }, set: { hex in
                        var updated = current
                        updated.colorHex = hex
                        save(updated)
                    }))
                }
                Divider()
                SettingRow(title: "Config directory",
                           detail: current.isDefault ? "Default runs with CLAUDE_CONFIG_DIR unset, so it keeps your existing sign-in." : nil) {
                    HStack(spacing: Space.xs) {
                        PathText(path: current.configDir, paths: model.paths, font: .rowDetail)
                            .frame(maxWidth: 260, alignment: .trailing)
                        if !current.isDefault {
                            Button("Change…", action: changeDirectory)
                        }
                    }
                }
                if !FileManager.default.fileExists(atPath: current.configDir) {
                    InlineMessage(kind: .warning, text: "This directory doesn't exist.") {
                        Button("Create Directory", action: createDirectory).controlSize(.small)
                    }
                }
            }
            if let basicsError {
                InlineMessage(kind: .error, text: basicsError) { self.basicsError = nil }
            }
        }
    }

    private var removeCard: some View {
        Card {
            SettingRow(title: "Remove profile",
                       detail: current.isDefault
                           ? "The Default profile can't be removed."
                           : "Removes it from Claude Pool. You choose whether its directory stays or moves to the Trash.") {
                Button("Remove Profile…", role: .destructive, action: onRemove)
                    .disabled(current.isDefault)
            }
        }
    }

    // MARK: Actions

    private func save(_ updated: Profile) {
        do {
            try model.profileStore.update(updated)
            basicsError = nil
        } catch {
            basicsError = error.localizedDescription
        }
    }

    private func saveName() {
        var updated = current
        updated.name = name
        save(updated)
        if basicsError != nil { name = current.name }
    }

    private func changeDirectory() {
        guard !current.trackingEnabled else {
            basicsError = "Turn off usage tracking first, so the old settings.json is restored, then change the directory."
            return
        }
        guard let url = Panels.chooseDirectory(startingAt: current.configDir) else { return }
        var updated = current
        updated.configDir = url.standardizedFileURL.path
        save(updated)
        model.refreshLocalState()
    }

    private func createDirectory() {
        do {
            try AtomicFile.ensureDirectory(current.configURL, permissions: 0o700)
            basicsError = nil
            model.refreshLocalState()
        } catch {
            basicsError = "Couldn't create \(current.configDir): \(error.localizedDescription). Check that the parent folder exists and is writable."
        }
    }

    private func launch(signIn: Bool) {
        Task {
            do {
                try await model.openTerminal(current, forSignIn: signIn)
                actionError = nil
                if signIn { signInHint = true }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// Confirmation for removing a profile. The default choice keeps the directory.
struct DeleteProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    @State private var moveToTrash = false
    @State private var restoreSettings = true
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: "Remove “\(profile.name)”?", subtitle: "Running claude sessions keep working; new launches can no longer pick this profile.") {
            Picker("What to remove", selection: $moveToTrash) {
                Text("Remove the profile only").tag(false)
                Text("Remove the profile and move its directory to the Trash").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(moveToTrash
                 ? "\(model.paths.abbreviate(profile.configDir)) moves to the Trash with its settings and sign-in fallback file. You can put it back from the Trash."
                 : "\(model.paths.abbreviate(profile.configDir)) stays on disk. You can adopt it again later.")
                .font(.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if profile.trackingEnabled {
                Toggle("Restore the original status line in settings.json first", isOn: $restoreSettings)
            }
            if let error { InlineMessage(kind: .error, text: error) }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(moveToTrash ? "Remove and Move to Trash" : "Remove Profile", role: .destructive) {
                do {
                    try model.deleteProfile(profile, moveDirectoryToTrash: moveToTrash, restoreSettings: restoreSettings)
                    dismiss()
                } catch {
                    self.error = "\(error.localizedDescription) Nothing was removed; try again or choose “Remove the profile only”."
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
