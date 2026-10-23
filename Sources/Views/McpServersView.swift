import SwiftUI

/// Every MCP server of every profile, with its sign-in state per profile, and the actions:
/// sign in (one profile, or every profile that needs it), sign out, add and remove.
struct McpServersView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    @State private var actionError: String?
    @State private var confirmation: McpConfirmation?

    var body: some View {
        let profiles = model.profiles
        let rows = model.mcpStore.rows(for: profiles)
        let pending = model.pendingMcpSignIns
        Page {
            PageHeader(title: "MCP Servers", subtitle: subtitle) {
                if model.mcpStore.isRefreshing { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.refreshMcp() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.mcpStore.isRefreshing || model.binary == nil)
                .help("Ask Claude Code for every profile's servers and their state again")
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Server…", systemImage: "plus")
                }
                .disabled(model.binary == nil)
                if !pending.isEmpty {
                    Button("Sign In to All (\(pending.count))…") { signIn(pending) }
                        .buttonStyle(.borderedProminent)
                        .help("Sign in every server that needs it, profile by profile")
                }
            }
        } content: {
            if let actionError {
                InlineMessage(kind: .error, text: actionError) { self.actionError = nil }
            }
            ForEach(profiles.filter { model.mcpStore.errors[$0.id] != nil }) { profile in
                InlineMessage(kind: .warning, text: "Couldn't check \(profile.name): \(model.mcpStore.errors[profile.id] ?? "")")
            }
            if rows.isEmpty {
                emptyCard
            } else {
                ForEach(McpServerGroup.Section.allCases) { section in
                    let sectionRows = rows.filter { section.contains($0.kind) }
                    if !sectionRows.isEmpty {
                        McpServerGroup(section: section, rows: sectionRows, profiles: profiles,
                                       onSignIn: signIn, onConfirm: { confirmation = $0 })
                    }
                }
                McpLegend()
            }
            Text("Each profile is its own Claude Code configuration, so each one signs in to a server once; your browser's sign-in to the service is reused, so it's one approval per profile. Claude Pool runs Claude Code's own `claude mcp` commands and never sees the tokens.")
                .font(.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.refreshMcpIfStale() }
        .sheet(isPresented: $showingAdd) { McpAddServerSheet() }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            presenting: confirmation) { item in
            Button(item.actionTitle, role: .destructive) { perform(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }

    private var subtitle: String {
        let dates = model.profiles.compactMap { model.mcpStore.checkedAt[$0.id] }
        guard let oldest = dates.min() else { return "Servers each profile can use, and their sign-ins." }
        return "Checked \(model.formatting.age(since: oldest)) · sign-ins are kept by Claude Code in each profile"
    }

    @ViewBuilder
    private var emptyCard: some View {
        Card {
            if model.mcpStore.isRefreshing {
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("Asking Claude Code for each profile's servers. Checking every server can take up to half a minute.")
                        .foregroundStyle(.secondary)
                }
            } else if model.binary == nil {
                MissingBinaryBanner()
            } else {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("No MCP servers yet").font(.sectionTitle)
                    Text("Add one to give Claude Code tools such as Cloudflare, AWS, Neon or Polar. Servers that need an account sign in through your browser.")
                        .font(.rowDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Add Server…") { showingAdd = true }
                }
            }
        }
    }

    private func signIn(_ steps: [McpSignInStep]) {
        Task {
            do { try await model.beginMcpSignIn(steps) } catch { actionError = error.localizedDescription }
        }
    }

    private func perform(_ item: McpConfirmation) {
        Task {
            do {
                switch item.action {
                case .signOut: try await model.signOutMcpServer(item.serverName, on: item.profiles)
                case .remove: try await model.removeMcpServer(item.serverName, from: item.profiles)
                }
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// A sign-out or removal waiting for confirmation.
struct McpConfirmation: Identifiable {
    enum Action { case signOut, remove }
    let id = UUID()
    let action: Action
    let serverName: String
    let profiles: [Profile]
    var sharedExtensions = false

    private var server: String { McpServer.displayName(for: serverName) }
    private var where_: String { profiles.count == 1 ? "“\(profiles[0].name)”" : "\(profiles.count) profiles" }

    var title: String {
        switch action {
        case .signOut: "Sign out of \(server) in \(where_)?"
        case .remove: sharedExtensions ? "Remove \(server) from every profile?" : "Remove \(server) from \(where_)?"
        }
    }

    var actionTitle: String { action == .signOut ? "Sign Out" : "Remove" }

    var message: String {
        switch action {
        case .signOut:
            "Claude Code forgets the saved sign-in. Sessions already running may keep using it until they restart. You can sign in again at any time."
        case .remove:
            "Runs claude mcp remove \(serverName). Claude Code stops offering its tools, and its saved sign-in is no longer used. You can add it again later."
                + (sharedExtensions ? " Shared Extensions is on, so it is removed from every profile." : "")
        }
    }
}

/// One card of servers (yours, plugins', or claude.ai connectors') as a profile × server grid.
struct McpServerGroup: View {
    enum Section: String, CaseIterable, Identifiable {
        case yours, plugins, connectors
        var id: String { rawValue }

        func contains(_ kind: McpServer.Kind) -> Bool {
            switch self {
            case .yours: kind == .remote || kind == .local
            case .plugins: kind == .plugin
            case .connectors: kind == .connector
            }
        }

        var title: String {
            switch self {
            case .yours: "Your Servers"
            case .plugins: "From Plugins"
            case .connectors: "claude.ai Connectors"
            }
        }

        var subtitle: String {
            switch self {
            case .yours: "Added with claude mcp add or here. With Shared Extensions on, every profile has the same ones."
            case .plugins: "Come with installed plugins. Remove them by turning the plugin off."
            case .connectors: "Come from each account's claude.ai settings, so they can differ between profiles. Their sign-in finishes on claude.ai."
            }
        }
    }

    @Environment(AppModel.self) private var model
    let section: Section
    let rows: [McpServerRow]
    let profiles: [Profile]
    let onSignIn: ([McpSignInStep]) -> Void
    let onConfirm: (McpConfirmation) -> Void

    var body: some View {
        Card(title: section.title, subtitle: section.subtitle) {
            Grid(alignment: .leading, horizontalSpacing: Space.xs, verticalSpacing: Space.xs) {
                GridRow {
                    Text("Server").font(.meta).foregroundStyle(.secondary)
                    ForEach(profiles) { profile in
                        VStack(spacing: 2) {
                            ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 18)
                            Text(profile.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(width: McpStatusCell.width)
                        .gridColumnAlignment(.center)
                        .help(profile.name)
                        .accessibilityElement(children: .combine)
                    }
                    Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                }
                ForEach(rows) { row in
                    Divider().gridCellColumns(profiles.count + 2)
                    GridRow {
                        McpServerTitle(row: row)
                        ForEach(profiles) { profile in
                            McpStatusCell(row: row, profile: profile, onSignIn: onSignIn, onConfirm: onConfirm)
                        }
                        actions(row)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ row: McpServerRow) -> some View {
        let needing = row.profilesNeedingSignIn(profiles)
        let signedIn = row.profilesSignedIn(profiles)
        HStack(spacing: Space.xxs) {
            if !needing.isEmpty {
                Button(needing.count == 1 ? "Sign In…" : "Sign In (\(needing.count))…") {
                    onSignIn(needing.map { McpSignInStep(profile: $0, serverName: row.name) })
                }
                .help(needing.count == 1 ? "Sign in on \(needing[0].name)" : "Sign in on \(needing.map(\.name).joined(separator: ", ")), one after another")
            }
            Menu {
                let having = row.profilesHaving(profiles)
                if row.reference.supportsSignIn {
                    Button("Sign In Again on Every Profile…") {
                        onSignIn(having.filter { row.entries[$0.id]?.supportsSignIn == true }.map { McpSignInStep(profile: $0, serverName: row.name) })
                    }
                }
                if !signedIn.isEmpty {
                    Button("Sign Out Everywhere…") {
                        onConfirm(McpConfirmation(action: .signOut, serverName: row.name, profiles: signedIn))
                    }
                }
                Button("Check Again") {
                    Task { for profile in having { await model.mcpStore.recheck(row.name, on: profile, binary: model.binary) } }
                }
                if row.reference.isRemovable {
                    Divider()
                    Button("Remove…") {
                        onConfirm(McpConfirmation(action: .remove, serverName: row.name, profiles: having,
                                                  sharedExtensions: model.settings.shareExtensions))
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(row.reference.displayName)")
        }
    }
}

/// Name, source and address of a server.
private struct McpServerTitle: View {
    let row: McpServerRow

    var body: some View {
        let server = row.reference
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Space.xxs) {
                Text(server.displayName).font(.rowTitle.weight(.medium)).lineLimit(1)
                if let plugin = McpServer.pluginName(for: row.name) {
                    Text(plugin).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .help("From the \(plugin) plugin")
                }
            }
            Text(detail(server))
                .font(.meta.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(server.target)
        }
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ server: McpServer) -> String {
        if server.target.isEmpty { return server.transport.map { "\($0) · no address" } ?? "—" }
        if server.kind == .local { return "\(server.target) · runs on this Mac" }
        return server.target
    }
}

/// One profile's state for one server: a symbol with a tooltip, and its actions on click.
struct McpStatusCell: View {
    static let width: CGFloat = 54

    @Environment(AppModel.self) private var model
    let row: McpServerRow
    let profile: Profile
    let onSignIn: ([McpSignInStep]) -> Void
    let onConfirm: (McpConfirmation) -> Void
    @State private var showingDetails = false

    var body: some View {
        let entry = row.entry(for: profile)
        Group {
            if model.mcpStore.isBusy(row.name, on: profile) || (entry == nil && model.mcpStore.refreshing.contains(profile.id)) {
                ProgressView().controlSize(.small)
            } else if let entry {
                // A plain button keeps the symbol's colour (a Menu label is drawn as a template).
                Button {
                    if entry.health == .needsSignIn, entry.supportsSignIn {
                        onSignIn([McpSignInStep(profile: profile, serverName: row.name)])
                    } else {
                        showingDetails = true
                    }
                } label: {
                    McpHealthSymbol(health: entry.health)
                }
                .buttonStyle(.plain)
                .contextMenu { menu(entry) }
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) { details(entry) }
            } else {
                Image(systemName: "minus")
                    .foregroundStyle(.tertiary)
                    .help("\(profile.name): not in this profile")
                    .accessibilityLabel("\(profile.name): not in this profile")
            }
        }
        .frame(width: Self.width, height: Metrics.minHitTarget)
        .help(entry.map { "\(profile.name): \(McpHealthSymbol.describe($0.health))" } ?? "")
        .accessibilityLabel(entry.map { "\(profile.name): \(McpHealthSymbol.describe($0.health))" } ?? "\(profile.name)")
    }

    @ViewBuilder
    private func menu(_ entry: McpServer) -> some View {
        Text("\(profile.name): \(McpHealthSymbol.describe(entry.health))")
        if entry.supportsSignIn {
            Button(entry.health == .connected ? "Sign In Again…" : "Sign In…") {
                onSignIn([McpSignInStep(profile: profile, serverName: row.name)])
            }
        }
        if entry.supportsSignOut, entry.health == .connected {
            Button("Sign Out…") {
                onConfirm(McpConfirmation(action: .signOut, serverName: row.name, profiles: [profile]))
            }
        }
        Button("Check Again") {
            Task { await model.mcpStore.recheck(row.name, on: profile, binary: model.binary) }
        }
    }

    /// The state in words (with the full reason for a failure) and the same actions as the menu.
    private func details(_ entry: McpServer) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                ProfileAvatar(name: profile.name, colorHex: profile.colorHex, size: 20)
                Text("\(entry.displayName) on \(profile.name)").font(.sectionTitle)
            }
            Label {
                Text(McpHealthSymbol.describe(entry.health)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } icon: {
                Image(systemName: McpHealthSymbol.symbol(entry.health)).foregroundStyle(McpHealthSymbol.tint(entry.health))
            }
            .font(.rowDetail)
            HStack(spacing: Space.xs) {
                if entry.supportsSignIn {
                    Button(entry.health == .connected ? "Sign In Again…" : "Sign In…") {
                        showingDetails = false
                        onSignIn([McpSignInStep(profile: profile, serverName: row.name)])
                    }
                }
                if entry.supportsSignOut, entry.health == .connected {
                    Button("Sign Out…") {
                        showingDetails = false
                        onConfirm(McpConfirmation(action: .signOut, serverName: row.name, profiles: [profile]))
                    }
                }
                Button("Check Again") {
                    showingDetails = false
                    Task { await model.mcpStore.recheck(row.name, on: profile, binary: model.binary) }
                }
            }
            .controlSize(.small)
        }
        .padding(Space.md)
        .frame(width: 320, alignment: .leading)
    }
}

/// Symbol and words for a server's state. Meaning never rests on colour alone.
struct McpHealthSymbol: View {
    let health: McpServer.Health

    var body: some View {
        Image(systemName: Self.symbol(health))
            .font(.body)
            .foregroundStyle(Self.tint(health))
            .frame(width: Metrics.minHitTarget, height: Metrics.minHitTarget)
            .contentShape(Rectangle())
    }

    static func symbol(_ health: McpServer.Health) -> String {
        switch health {
        case .connected: "checkmark.circle.fill"
        case .needsSignIn: "key.fill"
        case .failed: "xmark.octagon.fill"
        case .notConfigured: "circle.dashed"
        case .pendingApproval: "pause.circle"
        case .other: "questionmark.circle"
        }
    }

    static func tint(_ health: McpServer.Health) -> Color {
        switch health {
        case .connected: .statusOK
        case .needsSignIn: .statusWarn
        case .failed: .statusFail
        default: .secondary
        }
    }

    static func describe(_ health: McpServer.Health) -> String {
        switch health {
        case .connected: "Connected"
        case .needsSignIn: "Needs sign-in"
        case let .failed(reason): reason.map { "Can't connect: \($0)" } ?? "Can't connect"
        case .notConfigured: "Not configured"
        case .pendingApproval: "Waiting for approval in a project"
        case let .other(text): text
        }
    }
}

/// What the symbols mean.
private struct McpLegend: View {
    var body: some View {
        HStack(spacing: Space.md) {
            item(.connected)
            item(.needsSignIn, extra: " (click to sign in)")
            item(.failed(nil))
            HStack(spacing: Space.xxs) {
                Image(systemName: "minus").foregroundStyle(.tertiary)
                Text("Not in this profile")
            }
        }
        .font(.meta)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func item(_ health: McpServer.Health, extra: String = "") -> some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: McpHealthSymbol.symbol(health)).foregroundStyle(McpHealthSymbol.tint(health))
            Text(McpHealthSymbol.describe(health) + extra)
        }
    }
}
