import SwiftUI

/// The manager window: a sidebar of destinations and profiles, one page on the right.
struct ManagerWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    @State private var showingAdopt = false
    @State private var deleting: Profile?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                banners
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Claude Pool")
        .sheet(item: $model.trackingRequest) { TrackingConfirmSheet(request: $0) }
        .sheet(isPresented: $showingAdd) { AddAccountSheet() }
        .sheet(item: $model.signInRequest) { SignInSheet(profile: $0) }
        .sheet(isPresented: $showingAdopt) { AdoptExistingSheet() }
        .sheet(item: $deleting) { DeleteProfileSheet(profile: $0) }
        .task { await model.managerWindowOpened() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.usageStore.reload()
            model.refreshLocalState()
        }
        .onChange(of: model.profiles.map(\.id)) { _, ids in
            if case let .profile(id) = model.route, !ids.contains(id) { model.route = .overview }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        @Bindable var model = model
        return List(selection: Binding<ManagerRoute?>(get: { model.route }, set: { if let route = $0 { model.route = route } })) {
            Label("Overview", systemImage: "square.grid.2x2")
                .tag(ManagerRoute.overview)
            Label("Sessions", systemImage: "terminal")
                .badge(model.sessionsOnOtherProfiles.count)
                .tag(ManagerRoute.sessions)
                .help("Running claude sessions and the account each one uses")
            Label("Usage Analytics", systemImage: "chart.bar.xaxis")
                .tag(ManagerRoute.analytics)
            Label("Status Line", systemImage: "rectangle.bottomthird.inset.filled")
                .tag(ManagerRoute.statusline)

            Section("Profiles") {
                ForEach(model.profiles) { profile in
                    SidebarProfileRow(profile: profile)
                        .tag(ManagerRoute.profile(profile.id))
                        .contextMenu { profileMenu(profile) }
                }
                .onMove { model.profileStore.move(fromOffsets: $0, toOffset: $1) }
            }

            Section("App") {
                Label("Diagnostics", systemImage: "stethoscope")
                    .badge(model.diagnosticsIssueCount)
                    .tag(ManagerRoute.diagnostics)
                Label("Settings", systemImage: "gearshape")
                    .tag(ManagerRoute.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: Space.xs) {
                    Menu {
                        Button("Add Account…") { showingAdd = true }
                        Button("Adopt Existing Directories…") { showingAdopt = true }
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add and sign in an account, or adopt an existing directory")
                    Spacer()
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
            }
        }
    }

    @ViewBuilder
    private func profileMenu(_ profile: Profile) -> some View {
        Button("Set Active") { model.setActive(profile) }
            .disabled(model.profileStore.activeProfileID == profile.id)
        Button("Open Terminal") { OpenTerminalAction.run(profile, model: model) }
            .disabled(model.binary == nil)
        Button("Sign In…") { model.signInRequest = profile }
            .disabled(model.binary == nil)
        Divider()
        Button("Remove Profile…") { deleting = profile }
            .disabled(profile.isDefault)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .overview:
            OverviewView()
        case .sessions:
            SessionsView()
        case .analytics:
            AnalyticsView()
        case .statusline:
            StatuslineView()
        case let .profile(id):
            if let profile = model.profileStore.profile(id: id) {
                ProfileDetailView(profile: profile, onRemove: { deleting = profile })
                    .id(profile.id)
            } else {
                OverviewView()
            }
        case .diagnostics:
            DiagnosticsView()
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private var banners: some View {
        let messages: [(String, MessageKind, () -> Void)] = [
            model.binary == nil && !model.isLocatingBinary ? ("Claude Code wasn't found. Install it, or set its path in Settings › Claude Code.", .error, {}) : nil,
            model.startupError.map { ($0, .error, { model.startupError = nil }) },
            model.trackingError.map { ($0, .warning, { model.trackingError = nil }) },
        ].compactMap { $0 }
        if !messages.isEmpty {
            VStack(spacing: Space.xs) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    InlineMessage(kind: message.1, text: message.0, onDismiss: message.1 == .error && message.0.hasPrefix("Claude Code wasn't") ? nil : message.2)
                }
            }
            .frame(maxWidth: Metrics.pageMaxWidth)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
        }
    }
}

/// Sidebar row: avatar, name, active mark, and a one-line usage or state summary.
struct SidebarProfileRow: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        let isActive = model.profileStore.activeProfileID == profile.id
        let five = model.usageState(profile, .fiveHour)
        let seven = model.usageState(profile, .sevenDay)
        HStack(spacing: Space.xs) {
            ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xxs) {
                    Text(profile.name).lineLimit(1).help(profile.name)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Active")
                            .help("Active profile")
                    }
                }
                Text(summary(five, seven))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "5h 23% · 7d 41%", or the shared state ("Signed out", "Tracking off").
    private func summary(_ five: UsageWindowState, _ seven: UsageWindowState) -> String {
        func part(_ kind: UsageWindowKind, _ state: UsageWindowState) -> String? {
            switch state {
            case let .fresh(window, _), let .stale(window, _): "\(kind.shortLabel) \(UsageFormatting.percentText(window.usedPercentage))"
            case .resetPassed: "\(kind.shortLabel) reset"
            default: nil
            }
        }
        let parts = [part(.fiveHour, five), part(.sevenDay, seven)].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        switch five {
        case .trackingOff: return "Tracking off"
        case .signedOut: return "Signed out"
        case .notReported: return "Usage not reported"
        default: return "No data yet"
        }
    }
}
