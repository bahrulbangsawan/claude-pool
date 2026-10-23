import SwiftUI

/// The active profile, large: identity, both windows as rings, one primary action.
struct ActiveAccountCard: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    @State private var error: String?

    var body: some View {
        let formatting = model.formatting
        let five = model.usageState(profile, .fiveHour)
        let seven = model.usageState(profile, .sevenDay)
        Card {
            HStack(alignment: .center, spacing: Space.sm) {
                ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text(profile.name).font(.title3.weight(.semibold)).lineLimit(1).help(profile.name)
                        StatusBadge(text: "Active", systemImage: "checkmark.circle.fill", tint: .accentColor)
                        if let plan = model.authStore.plan(for: profile.id) { PlanBadge(plan: plan) }
                    }
                    IdentityLine(profile: profile)
                }
                Spacer(minLength: Space.md)
                CheckUsageButton(profile: profile) { error = $0 }
                    .buttonStyle(.borderless)
                Button("Details") { model.route = .profile(profile.id) }
                Button {
                    Task { do { try await model.openTerminal(profile) } catch { self.error = error.localizedDescription } }
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.binary == nil)
            }

            LaunchReadinessLine(profile: profile)
            AccountMismatchNote(profile: profile)
            ShellCoverageNote()
            let elsewhere = model.sessionsOnOtherProfiles
            if !elsewhere.isEmpty {
                InlineMessage(kind: .info, text: "\(elsewhere.count) running \(elsewhere.count == 1 ? "session still uses" : "sessions still use") another account. Running sessions keep the account they started with.") {
                    Button("Review Sessions…") { model.route = .sessions }.controlSize(.small)
                }
            }

            Divider()

            AvailabilityBadge(availability: model.availability(profile), formatting: formatting)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Space.lg) {
                    UsageRing(kind: .fiveHour, state: five, formatting: formatting)
                    UsageRing(kind: .sevenDay, state: seven, formatting: formatting)
                }
                VStack(alignment: .leading, spacing: Space.md) {
                    UsageRing(kind: .fiveHour, state: five, formatting: formatting)
                    UsageRing(kind: .sevenDay, state: seven, formatting: formatting)
                }
            }

            UsageFootnote(profile: profile, five: five, seven: seven)
            if let error { InlineMessage(kind: .error, text: error) { self.error = nil } }
        }
    }
}

/// Compact card for the grid: identity, both windows, quick actions.
struct AccountCard: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    @State private var error: String?

    private var isActive: Bool { model.profileStore.activeProfileID == profile.id }

    var body: some View {
        let formatting = model.formatting
        let five = model.usageState(profile, .fiveHour)
        let seven = model.usageState(profile, .sevenDay)
        Card {
            HStack(spacing: Space.xs) {
                ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).font(.rowTitle.weight(.semibold)).lineLimit(1).help(profile.name)
                    PathText(path: profile.configDir, paths: model.paths)
                }
                Spacer(minLength: Space.xs)
                if isActive {
                    StatusBadge(text: "Active", systemImage: "checkmark.circle.fill", tint: .accentColor)
                }
            }

            HStack(spacing: Space.xs) {
                if let plan = model.authStore.plan(for: profile.id) { PlanBadge(plan: plan) }
                let sessions = model.sessionStore.sessions(for: profile.id).count
                if sessions > 0 {
                    CountPill(count: sessions, text: sessions == 1 ? "session" : "sessions", tint: .accentColor)
                        .help("Running claude sessions using this profile's account")
                }
            }
            SignInLine(profile: profile)
            AccountMismatchNote(profile: profile, compact: true)
            AvailabilityBadge(availability: model.availability(profile), formatting: formatting)

            VStack(alignment: .leading, spacing: Space.sm) {
                UsageMeter(kind: .fiveHour, state: five, formatting: formatting,
                           onEnableTracking: { model.requestTrackingChange(profile, enable: true) },
                           onSignIn: { signIn() })
                UsageMeter(kind: .sevenDay, state: seven, formatting: formatting,
                           onEnableTracking: { model.requestTrackingChange(profile, enable: true) },
                           onSignIn: { signIn() })
            }
            .padding(.vertical, Space.xxs)

            UsageFootnote(profile: profile, five: five, seven: seven)
            if let error { InlineMessage(kind: .error, text: error) { self.error = nil } }

            Divider()
            HStack(spacing: Space.xs) {
                Button("Set Active") { model.setActive(profile) }
                    .disabled(isActive)
                Button {
                    Task { do { try await model.openTerminal(profile) } catch { self.error = error.localizedDescription } }
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .disabled(model.binary == nil)
                .help("Open Terminal with \(profile.name)")
                CheckUsageButton(profile: profile) { error = $0 }
                    .buttonStyle(.borderless)
                Spacer()
                Button {
                    model.route = .profile(profile.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: Metrics.minHitTarget, height: Metrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Show details for \(profile.name)")
                .accessibilityLabel("Details for \(profile.name)")
            }
            .controlSize(.small)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isActive ? 0.7 : 0), lineWidth: 1.5)
        )
    }

    private func signIn() {
        model.signInRequest = profile
    }
}

/// "Signed in · claude.ai subscription · team" with icon; or the problem.
struct SignInLine: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        let status = model.authStore.status(for: profile.id)
        HStack(spacing: Space.xxs) {
            if model.authStore.refreshing.contains(profile.id) {
                ProgressView().controlSize(.mini)
                Text("Checking sign-in…")
            } else if let status {
                Image(systemName: status.signedIn ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(status.signedIn ? Color.statusOK : Color.secondary)
                    .accessibilityHidden(true)
                Text(status.signedIn ? "Signed in" : "Signed out")
                    .foregroundStyle(.primary)
                if status.signedIn {
                    Text("· \(status.email ?? status.authMethodLabel)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("· checked \(model.formatting.age(since: status.checkedAt))")
                    .lineLimit(1)
                    .help("Last sign-in check: \(status.checkedAt.formatted(date: .abbreviated, time: .standard))")
            } else if let error = model.authStore.errors[profile.id] {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarn).accessibilityHidden(true)
                Text(error).lineLimit(2).help(error)
            } else {
                Image(systemName: "questionmark.circle").accessibilityHidden(true)
                Text("Sign-in not checked yet")
            }
        }
        .font(.meta)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Shown when another profile names the same account but its usage resets at different times,
/// so one of the two saved sign-ins is out of date (see `AccountMismatch`).
struct AccountMismatchNote: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    /// Narrow cards: a short line with the button below; the full text is in the tooltip.
    var compact = false

    var body: some View {
        let others = model.accountMismatches(for: profile)
        if !others.isEmpty {
            let names = others.map(\.name).joined(separator: ", ")
            let email = model.authStore.status(for: profile.id)?.email.map { " (\($0))" } ?? ""
            let text = "Shows the same account as \(names)\(email), but usage resets at different times, so they are different accounts. One saved sign-in is out of date. Sign in again to refresh it."
            if compact {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Label("Same account as \(names), but usage resets differ. A saved sign-in is out of date.", systemImage: "exclamationmark.triangle.fill")
                        .font(.meta)
                        .foregroundStyle(Color.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                    signInButton
                }
                .help(text)
            } else {
                InlineMessage(kind: .warning, text: text) { signInButton }
            }
        }
    }

    private var signInButton: some View {
        Button("Sign In Again…") { model.signInRequest = profile }
            .controlSize(.small)
            .disabled(model.binary == nil)
    }
}

/// Identity under the name: email · org · plan, or sign-in state.
struct IdentityLine: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        if let status = model.authStore.status(for: profile.id), status.signedIn {
            let parts = [status.identityLabel, model.authStore.plan(for: profile.id).map { "\($0.displayName) plan" }].compactMap { $0 }
            Text(parts.isEmpty ? status.authMethodLabel : parts.joined(separator: " · "))
                .font(.rowDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(parts.joined(separator: " · "))
        } else {
            SignInLine(profile: profile)
        }
    }
}

/// Observation age (+ stale note) and the reason no usage is reported, when relevant.
struct UsageFootnote: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let five: UsageWindowState
    let seven: UsageWindowState

    var body: some View {
        let stale = five.isStale || seven.isStale
        if let observed = model.usageStore.snapshot(for: profile.id)?.observedAt, five.displayedWindow != nil || seven.displayedWindow != nil {
            VStack(alignment: .leading, spacing: Space.xxs) {
                ObservationLabel(observedAt: observed, stale: stale, formatting: model.formatting)
                if stale {
                    Text(UsageFormatting.staleFootnote)
                        .font(.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let status = model.authStore.status(for: profile.id), status.signedIn, !status.reportsUsage {
            Text("Signed in with \(status.authMethodLabel), which overrides the subscription sign-in. Remove the exported key or apiKeyHelper, then run /login.")
                .font(.meta)
                .foregroundStyle(Color.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
