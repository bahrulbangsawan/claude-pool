import SwiftUI

/// Running Claude Code sessions, grouped by the profile (and so the account) each one uses.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var handoff: HandoffRequest?
    @State private var ending: ClaudeSession?
    @State private var error: String?

    var body: some View {
        Page {
            PageHeader(title: "Sessions", subtitle: subtitle) {
                Button {
                    model.sessionStore.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        } content: {
            InlineMessage(kind: .info, text: "A running claude keeps the account it started with — switching only affects new launches. To move a conversation to another account, choose Continue On: Claude Pool copies the conversation to that profile and resumes it in a new Terminal window. The original session is not touched.")
            if let error { InlineMessage(kind: .error, text: error) { self.error = nil } }
            handoffList
            if model.sessionStore.sessions.isEmpty {
                Card {
                    VStack(spacing: Space.xs) {
                        Image(systemName: "terminal").font(.title2).foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text("No running sessions").font(.sectionTitle)
                        Text("Sessions appear here while claude runs with any profile.").font(.rowDetail).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.lg)
                }
            }
            ForEach(model.profiles) { profile in
                let sessions = model.sessionStore.sessions(for: profile.id)
                if !sessions.isEmpty {
                    ProfileSessionsCard(profile: profile, sessions: sessions, onHandoff: { handoff = $0 }, onEnd: { ending = $0 })
                }
            }
        }
        .sheet(item: $handoff) { HandoffSheet(request: $0) }
        .confirmationDialog("End this session?", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }), presenting: ending) { session in
            Button("End Session", role: .destructive) {
                do { try model.endSession(session) } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Claude Pool asks claude (pid \(session.pid)) in \(session.folderName) to quit, as if you closed it. The conversation is saved and can be resumed.")
        }
    }

    private var subtitle: String {
        let count = model.sessionStore.sessions.count
        let elsewhere = model.sessionsOnOtherProfiles.count
        var text = "\(count) running"
        if elsewhere > 0, let active = model.profileStore.activeProfile { text += " · \(elsewhere) not on \(active.name)" }
        return text
    }

    @ViewBuilder
    private var handoffList: some View {
        let handoffs = model.sessionStore.handoffs
        if !handoffs.isEmpty {
            Card(title: "Conversations moved") {
                VStack(spacing: Space.xs) {
                    ForEach(handoffs) { handoff in
                        HandoffRow(handoff: handoff)
                        if handoff.id != handoffs.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

struct HandoffRequest: Identifiable {
    let id = UUID()
    let session: ClaudeSession
    var target: Profile?
}

private struct HandoffRow: View {
    @Environment(AppModel.self) private var model
    let handoff: SessionHandoff

    var body: some View {
        let source = model.profileStore.profile(id: handoff.sourceProfileID)
        let target = model.profileStore.profile(id: handoff.targetProfileID)
        HStack(spacing: Space.sm) {
            switch handoff.state {
            case .pending:
                ProgressView().controlSize(.small)
            case .confirmed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.statusOK).accessibilityHidden(true)
            case .unconfirmed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarn).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(URL(fileURLWithPath: handoff.cwd).lastPathComponent): \(source?.name ?? "?") → \(target?.name ?? "?")")
                    .font(.rowTitle)
                Text(stateText(target: target)).font(.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if handoff.state != .pending {
                Button("Dismiss") { model.sessionStore.dismissHandoff(handoff.id) }.controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stateText(target: Profile?) -> String {
        switch handoff.state {
        case .pending:
            return "Waiting for Claude Code to start the resumed session under \(target?.name ?? "the new profile")…"
        case let .confirmed(pid):
            let account = target.flatMap { model.authStore.status(for: $0.id)?.email }
            return "Confirmed: running as pid \(pid) under \(target?.name ?? "the new profile")\(account.map { " (\($0))" } ?? ""). You can end the old session."
        case .unconfirmed:
            return "Not confirmed after \(Int(SessionStore.confirmationTimeout / 60)) minutes. Check the Terminal window (for example a folder-trust prompt or an error)."
        }
    }
}

private struct ProfileSessionsCard: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let sessions: [ClaudeSession]
    let onHandoff: (HandoffRequest) -> Void
    let onEnd: (ClaudeSession) -> Void

    var body: some View {
        let isActive = model.profileStore.activeProfileID == profile.id
        let status = model.authStore.status(for: profile.id)
        Card {
            HStack(spacing: Space.xs) {
                ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Space.xs) {
                        Text(profile.name).font(.rowTitle.weight(.semibold))
                        if isActive { StatusBadge(text: "Active", systemImage: "checkmark.circle.fill", tint: .accentColor) }
                        if let plan = model.authStore.plan(for: profile.id) { PlanBadge(plan: plan) }
                    }
                    Text(status?.signedIn == true ? "Sessions here use \(status?.email ?? "this profile's account")" : "Sessions here use this profile's sign-in")
                        .font(.meta).foregroundStyle(.secondary)
                }
                Spacer()
                AvailabilityBadge(availability: model.availability(profile), formatting: model.formatting)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            Divider()
            VStack(spacing: Space.xs) {
                ForEach(sessions) { session in
                    SessionRow(session: session, profile: profile, onHandoff: onHandoff, onEnd: onEnd)
                    if session.id != sessions.last?.id { Divider() }
                }
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ClaudeSession
    let profile: Profile
    let onHandoff: (HandoffRequest) -> Void
    let onEnd: (ClaudeSession) -> Void

    var body: some View {
        let others = model.profiles.filter { $0.id != profile.id }
        let isActiveProfile = model.profileStore.activeProfileID == profile.id
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: session.isBusy ? "bolt.circle.fill" : "moon.circle")
                .foregroundStyle(session.isBusy ? Color.accentColor : Color.secondary)
                .font(.title3)
                .accessibilityLabel(session.isBusy ? "Working" : "Idle")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(session.name ?? session.folderName).font(.rowTitle).lineLimit(1)
                    if !isActiveProfile, let active = model.profileStore.activeProfile {
                        StatusBadge(text: "Not on \(active.name)", systemImage: "arrow.triangle.branch", tint: .statusWarn)
                            .help("This session keeps \(profile.name)'s account. New launches use \(active.name).")
                    }
                }
                PathText(path: session.cwd, paths: model.paths)
                Text(meta).font(.meta).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.sm)
            Menu {
                ForEach(others) { target in
                    let status = model.authStore.status(for: target.id)
                    Button {
                        onHandoff(HandoffRequest(session: session, target: target))
                    } label: {
                        Text("\(target.name)\(status?.email.map { " — \($0)" } ?? "")\(status?.signedIn == false ? " (signed out)" : "")")
                    }
                }
            } label: {
                Label(isActiveProfile ? "Continue On…" : "Continue On \(model.profileStore.activeProfile?.name ?? "…")", systemImage: "arrow.right.circle")
            } primaryAction: {
                if !isActiveProfile, let active = model.profileStore.activeProfile {
                    onHandoff(HandoffRequest(session: session, target: active))
                } else if let first = others.first {
                    onHandoff(HandoffRequest(session: session, target: first))
                }
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(others.isEmpty || model.binary == nil)
            .help("Resume this conversation with another profile's account")
            Button("End…") { onEnd(session) }
                .disabled(session.isBusy)
                .help(session.isBusy ? "Working on a response; end it from its Terminal window" : "Ask this claude process to quit")
        }
        .controlSize(.small)
    }

    private var meta: String {
        var parts = ["pid \(session.pid)"]
        if let status = session.status { parts.append(status) }
        if let started = session.startedAt { parts.append("started \(model.formatting.age(since: started))") }
        if let version = session.version { parts.append("v\(version)") }
        if let usage = model.resourceStore.usage(for: session.pid) {
            parts.append("CPU \(MenuBarText.cpu(usage.cpuPercent))")
            parts.append(MenuBarText.bytes(usage.memory))
        }
        return parts.joined(separator: " · ")
    }
}

/// Confirms moving a conversation, showing exactly what will and won't happen.
struct HandoffSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: HandoffRequest
    @State private var target: Profile?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let source = model.profileStore.profile(id: request.session.profileID)
        SheetScaffold(title: "Continue This Conversation on Another Account",
                      subtitle: "\(request.session.name ?? request.session.folderName) · now on \(source?.name ?? "?")") {
            Picker("Continue on", selection: $target) {
                ForEach(model.profiles.filter { $0.id != request.session.profileID }) { profile in
                    Text(profile.name).tag(Optional(profile))
                }
            }
            if let target {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    AvailabilityBadge(availability: model.availability(target), formatting: model.formatting)
                    if model.authStore.refreshing.contains(target.id) {
                        HStack(spacing: Space.xxs) { ProgressView().controlSize(.mini); Text("Checking \(target.name)'s sign-in…") }
                            .font(.meta).foregroundStyle(.secondary)
                    } else if let status = model.authStore.status(for: target.id) {
                        Text(status.signedIn ? "Signed in as \(status.email ?? "unknown")" : "Signed out — sign it in first")
                            .font(.meta).foregroundStyle(status.signedIn ? Color.secondary : Color.statusWarn)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Label("Copies the conversation file into the other profile (existing copies are kept as backups).", systemImage: "doc.on.doc")
                Label("Opens Terminal in \(model.paths.abbreviate(request.session.cwd)) running claude --resume with that profile.", systemImage: "terminal")
                Label("Leaves the current session running; you can end it once the new one is confirmed.", systemImage: "hand.raised")
                Label("Never moves credentials and never re-sends anything automatically.", systemImage: "lock")
            }
            .font(.rowDetail)
            .foregroundStyle(.secondary)
            if request.session.isBusy {
                InlineMessage(kind: .warning, text: "This session is working on a response right now. The copy includes only what has been saved so far.")
            }
            if let error { InlineMessage(kind: .error, text: error) }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                guard let target else { return }
                working = true
                Task {
                    do {
                        try await model.handOff(request.session, to: target)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                    working = false
                }
            } label: {
                if working { ProgressView().controlSize(.small) } else { Text("Continue on \(target?.name ?? "…")") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(target == nil || working || model.binary == nil)
        }
        .onAppear {
            target = request.target
            if let target = request.target { Task { await model.refreshAuth(target) } }
        }
    }
}
