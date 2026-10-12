import SwiftUI

/// The menu bar panel: a compact per-account summary in the user's order.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(Space.sm)

            if model.binary == nil, !model.isLocatingBinary {
                MissingBinaryBanner().padding([.horizontal, .bottom], Space.sm)
            }
            if let error = launchError ?? model.profileStore.lastError {
                InlineMessage(kind: .error, text: error) {
                    launchError = nil
                    model.profileStore.lastError = nil
                }
                .padding([.horizontal, .bottom], Space.sm)
            }

            if let active = model.profileStore.activeProfile {
                LaunchReadinessLine(profile: active)
                    .padding([.horizontal, .bottom], Space.sm)
                if let suggestion = model.suggestedProfile {
                    SuggestionRow(active: active, suggestion: suggestion)
                        .padding([.horizontal, .bottom], Space.sm)
                }
            }
            if !model.sessionsOnOtherProfiles.isEmpty {
                Button {
                    openManager(.sessions)
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.statusWarn)
                        Text("\(model.sessionsOnOtherProfiles.count) running \(model.sessionsOnOtherProfiles.count == 1 ? "session uses" : "sessions use") another account")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.rowDetail)
                    .padding(.horizontal, Space.sm)
                    .padding(.bottom, Space.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()
            VStack(spacing: 2) {
                ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                    MenuProfileRow(profile: profile, index: index, launchError: $launchError)
                }
            }
            .padding(Space.xxs + 2)

            if model.diagnosticsNeedAttention {
                Divider()
                Button {
                    openManager(.diagnostics)
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarn)
                        Text("\(model.diagnosticsIssueCount) \(model.diagnosticsIssueCount == 1 ? "check needs" : "checks need") attention")
                        Spacer()
                        Text("Diagnostics").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.rowDetail)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()
            ResourceSummary()
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)

            Divider()
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Switching applies to new claude launches; running sessions keep their account. Usage is what Claude Code last reported for each account.")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Claude Pool…") { openManager(nil) }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                }
            }
            .padding(Space.sm)
        }
        .frame(width: Metrics.menuWidth)
        .onAppear {
            model.usageStore.reload()
            model.refreshLocalState()
        }
    }

    private var header: some View {
        let active = model.profileStore.activeProfile
        return HStack(spacing: Space.xs) {
            if let active {
                ProfileAvatar(name: active.name, colorHex: active.colorHex, size: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Active: \(active?.name ?? "Unregistered directory")")
                    .font(.sectionTitle)
                    .lineLimit(1)
                    .help(active?.name ?? "")
                PathText(path: active?.configDir ?? model.profileStore.unknownActiveDirectory ?? "", paths: model.paths)
            }
            Spacer(minLength: 0)
        }
    }

    private func openManager(_ route: ManagerRoute?) {
        if let route { model.route = route }
        openWindow(id: "manager")
        NSApp.activate()
    }
}

private struct MenuProfileRow: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let index: Int
    @Binding var launchError: String?
    @State private var hovering = false

    private var isActive: Bool { model.profileStore.activeProfileID == profile.id }

    var body: some View {
        let formatting = model.formatting
        let five = model.usageState(profile, .fiveHour)
        let seven = model.usageState(profile, .sevenDay)

        HStack(spacing: Space.xxs) {
            Button {
                model.setActive(profile)
            } label: {
                HStack(spacing: Space.xs) {
                    ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Space.xxs) {
                            Text(profile.name)
                                .fontWeight(isActive ? .semibold : .regular)
                                .lineLimit(1)
                                .help(profile.name)
                            if isActive {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Active")
                            }
                            if case let .limited(until, _, _) = model.availability(profile) {
                                Label("limit · \(formatting.countdown(to: until))", systemImage: "hourglass")
                                    .font(.meta.monospacedDigit())
                                    .foregroundStyle(Color.statusFail)
                                    .help("A usage window is at 100% until \(until.formatted(date: .abbreviated, time: .shortened))")
                            }
                            Spacer(minLength: Space.xs)
                            if hasValues(five, seven), let observed = model.usageStore.snapshot(for: profile.id)?.observedAt {
                                ObservationLabel(observedAt: observed, stale: five.isStale || seven.isStale, formatting: formatting, compact: true)
                            }
                            if index < 9 {
                                Text("⌘\(index + 1)")
                                    .font(.meta.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        secondLine(five: five, seven: seven, formatting: formatting)
                    }
                }
                .padding(.vertical, 6)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(RowShortcut(index: index))
            .help(isActive ? "\(profile.name) is active" : "Make \(profile.name) the active profile")
            .accessibilityHint("Sets \(profile.name) as the active profile for new claude launches")

            Button {
                Task {
                    do { try await model.openTerminal(profile) } catch { launchError = error.localizedDescription }
                }
            } label: {
                Image(systemName: "terminal")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.binary == nil)
            .help("Open Terminal with \(profile.name)")
            .accessibilityLabel("Open Terminal with \(profile.name)")
            .padding(.trailing, Space.xxs)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : (isActive ? Color.accentColor.opacity(0.12) : .clear))
        )
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func secondLine(five: UsageWindowState, seven: UsageWindowState, formatting: UsageFormatting) -> some View {
        if let text = sharedStateText(five, seven) {
            Text(text)
                .font(.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: Space.md) {
                CompactUsageBar(kind: .fiveHour, state: five, formatting: formatting, barWidth: 48)
                CompactUsageBar(kind: .sevenDay, state: seven, formatting: formatting, barWidth: 48)
                Spacer(minLength: 0)
            }
        }
    }

    private func hasValues(_ a: UsageWindowState, _ b: UsageWindowState) -> Bool {
        a.displayedWindow != nil || b.displayedWindow != nil
    }

    /// One line when neither window has a value to draw.
    private func sharedStateText(_ a: UsageWindowState, _ b: UsageWindowState) -> String? {
        func textOnly(_ s: UsageWindowState) -> Bool {
            switch s {
            case .trackingOff, .signedOut, .notReported, .noData: true
            default: false
            }
        }
        guard textOnly(a), textOnly(b), a == b else { return nil }
        switch a {
        case .trackingOff: return "Usage tracking off"
        case .signedOut: return "Signed out"
        case .notReported: return "Usage not reported for this sign-in"
        default: return "No data yet — send a message in a claude session"
        }
    }
}

/// ⌘1–⌘9 on the first nine rows.
private struct RowShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}

/// Shown while the active account is near or at a limit and the suggestion is on. Switching stays
/// a click; nothing happens on its own.
private struct SuggestionRow: View {
    @Environment(AppModel.self) private var model
    let active: Profile
    let suggestion: Profile

    var body: some View {
        let limited = if case .limited = model.availability(active) { true } else { false }
        HStack(spacing: Space.xs) {
            Image(systemName: "lightbulb.fill").foregroundStyle(Color.statusWarn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(active.name) is \(limited ? "at a limit" : "close to a limit")")
                    .font(.rowDetail.weight(.medium))
                    .lineLimit(1)
                Text("Most room left: \(suggestion.name) · \(model.usageSummary(suggestion))")
                    .font(.meta.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.xs)
            Button("Switch") { model.setActive(suggestion) }
                .controlSize(.small)
                .help("Make \(suggestion.name) the active profile for new claude launches")
        }
        .padding(Space.xs)
        .background(Color.statusWarn.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// CPU and memory of the Mac and of all running claude sessions together.
private struct ResourceSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let resources = model.resourceStore
        let sessions = model.sessionStore.sessions
        Grid(alignment: .leading, horizontalSpacing: Space.sm, verticalSpacing: 3) {
            GridRow {
                Label("This Mac", systemImage: "desktopcomputer")
                if let system = resources.system {
                    Text("CPU \(MenuBarText.cpu(system.cpuPercent))")
                    Text("\(MenuBarText.bytes(system.memoryUsed)) of \(MenuBarText.bytes(system.memoryTotal))")
                } else {
                    Text("CPU –")
                    Text("Memory –")
                }
            }
            GridRow {
                Label(sessions.count == 1 ? "1 claude session" : "\(sessions.count) claude sessions", systemImage: "terminal")
                if let total = resources.total(for: sessions.map(\.pid)) {
                    Text("CPU \(MenuBarText.cpu(total.cpuPercent))")
                    Text(MenuBarText.bytes(total.memory))
                } else {
                    Text("—").gridCellColumns(2)
                }
            }
        }
        .font(.meta.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
