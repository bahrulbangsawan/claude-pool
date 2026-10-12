import SwiftUI

/// Full plan name ("Max 20x"). An unverified tier says so instead of guessing.
struct PlanBadge: View {
    let plan: SubscriptionPlan

    var body: some View {
        StatusBadge(text: plan.displayName, systemImage: plan.isTierKnown ? "crown.fill" : "crown",
                    tint: plan.isTierKnown ? .purple : .secondary)
            .help(helpText)
            .accessibilityLabel("Plan \(plan.displayName)")
    }

    private var helpText: String {
        switch plan.source {
        case .planName: "Plan name from the account profile Claude Code cached."
        case .rateLimitTier: "From Claude Code's account data: subscription type plus its rate-limit tier."
        case .subscriptionType: plan.isTierKnown
            ? "From claude auth status."
            : "claude auth status reports only “\(plan.family.label)”. The tier isn't in Claude Code's cached account data yet; it appears after Claude Code refreshes the profile (start a session)."
        }
    }
}

/// "Usable", "5-hour limit reached · resets 14:05 (in 2h)", from reported windows only.
struct AvailabilityBadge: View {
    let availability: AccountAvailability
    let formatting: UsageFormatting

    var body: some View {
        let (symbol, tint): (String, Color) = switch availability {
        case .signedOut: ("person.crop.circle.badge.xmark", .secondary)
        case .unknown: ("questionmark.circle", .secondary)
        case let .available(near, _): (near ? "gauge.with.dots.needle.67percent" : "checkmark.circle.fill", near ? .statusWarn : .statusOK)
        case .limited: ("hourglass", .statusFail)
        }
        Label(formatting.availabilityText(availability), systemImage: symbol)
            .font(.meta)
            .foregroundStyle(tint)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

extension AppModel {
    func availability(_ profile: Profile) -> AccountAvailability {
        AccountAvailability.evaluate(
            fiveHour: usageState(profile, .fiveHour),
            sevenDay: usageState(profile, .sevenDay),
            signedIn: authStore.status(for: profile.id)?.signedIn
        )
    }
}

/// What new `claude` launches will use, verified, with the reason when not ready.
struct LaunchReadinessLine: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        let readiness = model.launchReadiness(for: profile)
        HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
            switch readiness {
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Verifying the sign-in new launches will use…")
            case let .ready(status):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.statusOK).accessibilityHidden(true)
                Text("New claude launches use \(status.email ?? "this account")")
                    .lineLimit(1).truncationMode(.middle)
            case .signedOut:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarn).accessibilityHidden(true)
                Text("Selected, but this profile is signed out — new launches will ask you to sign in")
            case let .overridden(method):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarn).accessibilityHidden(true)
                Text("New launches use \(method), which overrides this profile's sign-in")
            case let .isolationBroken(dir):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.statusFail).accessibilityHidden(true)
                Text("Claude Code reports \(dir) instead of this profile's directory")
            case let .unverified(error):
                Image(systemName: "questionmark.circle").accessibilityHidden(true)
                Text("Couldn't verify: \(error)").lineLimit(2)
            case let .pointerMismatch(actual):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.statusFail).accessibilityHidden(true)
                Text("Switch not in effect: the active pointer names \(actual.map { model.paths.abbreviate($0) } ?? "Default")")
            case let .pointerUnreadable(error):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.statusFail).accessibilityHidden(true)
                Text("Can't read the active pointer: \(error)").lineLimit(2)
            }
        }
        .font(.meta)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// How plain `claude` in a new shell picks up the switch. Without the shell integration only
/// Claude Pool's own Terminal launches follow it.
struct ShellCoverageNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.shellStatus != .installed {
            InlineMessage(kind: .warning, text: "Shell integration isn't installed, so a plain claude in a new terminal still uses Default. Launches from Claude Pool use the selected profile.") {
                Button("Settings…") { model.route = .settings }.controlSize(.small)
            }
        }
    }
}

/// Count badge with a tint, for "3 sessions" style meta.
struct CountPill: View {
    let count: Int
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text("\(count) \(text)")
            .font(.meta.weight(.medium).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}
