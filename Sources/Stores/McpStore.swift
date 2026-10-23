import Foundation
import Observation

/// One server across every profile: what each profile's Claude Code reports for it.
struct McpServerRow: Identifiable, Hashable {
    let name: String
    /// What the first profile that has it reports (name, kind, address).
    let reference: McpServer
    var entries: [UUID: McpServer]

    var id: String { name }
    var kind: McpServer.Kind { reference.kind }

    func entry(for profile: Profile) -> McpServer? { entries[profile.id] }

    /// Profiles where this server waits for a sign-in, in the order given.
    func profilesNeedingSignIn(_ profiles: [Profile]) -> [Profile] {
        profiles.filter { entries[$0.id]?.health == .needsSignIn && entries[$0.id]?.supportsSignIn == true }
    }

    func profilesSignedIn(_ profiles: [Profile]) -> [Profile] {
        profiles.filter { entries[$0.id]?.health == .connected && entries[$0.id]?.supportsSignOut == true }
    }

    func profilesHaving(_ profiles: [Profile]) -> [Profile] {
        profiles.filter { entries[$0.id] != nil }
    }
}

/// One profile × one server sign-in in a queue.
struct McpSignInStep: Identifiable, Hashable {
    let profile: Profile
    let serverName: String
    var id: String { "\(profile.id.uuidString)|\(serverName)" }
}

/// MCP servers per profile from `claude mcp list`, in memory only. Checked when the MCP Servers
/// page opens (at most every few minutes) and on request: a check starts every stdio server and
/// contacts every remote one, so it never runs in the background.
@MainActor
@Observable
final class McpStore {
    static let staleAfter: TimeInterval = 10 * 60

    private(set) var servers: [UUID: [McpServer]] = [:]
    private(set) var checkedAt: [UUID: Date] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var refreshing: Set<UUID> = []
    /// "<profile>|<server>" with a sign-out, removal or re-check running.
    private(set) var busy: Set<String> = []

    let service: McpService

    init(service: McpService) {
        self.service = service
    }

    var isRefreshing: Bool { !refreshing.isEmpty }

    func refresh(_ profile: Profile, binary: ClaudeBinary?) async {
        guard let binary else {
            errors[profile.id] = AppModelError.binaryMissing.localizedDescription
            return
        }
        guard !refreshing.contains(profile.id) else { return }
        refreshing.insert(profile.id)
        defer { refreshing.remove(profile.id) }
        do {
            record(try await service.list(profile, binary: binary), for: profile.id)
        } catch {
            errors[profile.id] = error.localizedDescription
        }
    }

    func refreshAll(_ profiles: [Profile], binary: ClaudeBinary?) async {
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { await self.refresh(profile, binary: binary) }
            }
        }
    }

    /// Profiles never checked, or checked more than `staleAfter` ago.
    func refreshIfStale(_ profiles: [Profile], binary: ClaudeBinary?, now: Date = Date()) async {
        let due = profiles.filter { profile in
            guard let last = checkedAt[profile.id] else { return true }
            return now.timeIntervalSince(last) >= Self.staleAfter
        }
        guard !due.isEmpty else { return }
        await refreshAll(due, binary: binary)
    }

    /// Re-reads one server with `claude mcp get` (a few seconds instead of a full list).
    @discardableResult
    func recheck(_ name: String, on profile: Profile, binary: ClaudeBinary?) async -> McpServer? {
        guard let binary else { return nil }
        let key = Self.key(profile, name)
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let server = try await service.get(name, profile: profile, binary: binary)
            apply(server, named: name, for: profile.id)
            return server
        } catch {
            return entry(name, for: profile.id)
        }
    }

    func signOut(_ name: String, on profile: Profile, binary: ClaudeBinary) async throws {
        let key = Self.key(profile, name)
        busy.insert(key)
        defer { busy.remove(key) }
        try await service.signOut(name, profile: profile, binary: binary)
        if var server = entry(name, for: profile.id) {
            server.health = .needsSignIn
            apply(server, named: name, for: profile.id)
        }
    }

    func remove(_ name: String, from profile: Profile, binary: ClaudeBinary) async throws {
        let key = Self.key(profile, name)
        busy.insert(key)
        defer { busy.remove(key) }
        try await service.remove(name, profile: profile, binary: binary)
        apply(nil, named: name, for: profile.id)
    }

    func isBusy(_ name: String, on profile: Profile) -> Bool {
        busy.contains(Self.key(profile, name))
    }

    // MARK: Derived

    func entry(_ name: String, for id: UUID) -> McpServer? {
        servers[id]?.first { $0.name == name }
    }

    /// Every server any of `profiles` has, sorted by display name.
    func rows(for profiles: [Profile]) -> [McpServerRow] {
        var rows: [String: McpServerRow] = [:]
        for profile in profiles {
            for server in servers[profile.id] ?? [] {
                if rows[server.name] == nil {
                    rows[server.name] = McpServerRow(name: server.name, reference: server, entries: [:])
                }
                rows[server.name]?.entries[profile.id] = server
            }
        }
        return rows.values.sorted {
            $0.reference.displayName.localizedStandardCompare($1.reference.displayName) == .orderedAscending
        }
    }

    /// Every profile × server waiting for a sign-in, server by server, in profile order. claude.ai
    /// connectors are left out: an organisation can offer dozens, their sign-in finishes on
    /// claude.ai, and their own row still signs them in.
    func pendingSignIns(for profiles: [Profile]) -> [McpSignInStep] {
        rows(for: profiles).filter { $0.kind != .connector }.flatMap { row in
            row.profilesNeedingSignIn(profiles).map { McpSignInStep(profile: $0, serverName: row.name) }
        }
    }

    /// Whether any profile has a server at this address (for "Added" in Add Server).
    func hasServer(named name: String, orURL url: String) -> Bool {
        servers.values.contains { list in
            list.contains { $0.name == name || ($0.isRemote && McpCatalog.sameEndpoint($0.target, url)) }
        }
    }

    // MARK: Updates

    func record(_ list: [McpServer], for id: UUID, at date: Date = Date()) {
        servers[id] = list
        checkedAt[id] = date
        errors[id] = nil
    }

    func forget(_ id: UUID) {
        servers[id] = nil
        checkedAt[id] = nil
        errors[id] = nil
        refreshing.remove(id)
    }

    /// Sets (or with nil removes) one server of one profile.
    func apply(_ server: McpServer?, named name: String, for id: UUID) {
        guard var list = servers[id] else {
            if let server { servers[id] = [server] }
            return
        }
        if let index = list.firstIndex(where: { $0.name == name }) {
            if let server { list[index] = server } else { list.remove(at: index) }
        } else if let server {
            list.append(server)
        }
        servers[id] = list
    }

    private static func key(_ profile: Profile, _ name: String) -> String { "\(profile.id.uuidString)|\(name)" }
}

/// Signs several profile × server pairs in one after another, with one `McpLoginFlow` at a time,
/// so each sign-in has the localhost callback port to itself. A successful step moves on by
/// itself; a connector step waits for the user, since its link finishes on claude.ai.
@MainActor
@Observable
final class McpSignInQueue: Identifiable {
    enum Outcome: Equatable {
        case signedIn
        case finishOnClaudeAI
        case skipped
        case failed
    }

    let id = UUID()
    let steps: [McpSignInStep]
    private(set) var index = 0
    private(set) var outcomes: [String: Outcome] = [:]
    private(set) var flow: McpLoginFlow?
    private(set) var isComplete = false

    @ObservationIgnored private let makeFlow: @MainActor (McpSignInStep) -> McpLoginFlow
    @ObservationIgnored private let onStepFinished: @MainActor (McpSignInStep, Outcome) -> Void
    @ObservationIgnored private var advancing = false
    @ObservationIgnored static var advanceDelay: Duration = .milliseconds(900)

    init(steps: [McpSignInStep],
         makeFlow: @escaping @MainActor (McpSignInStep) -> McpLoginFlow,
         onStepFinished: @escaping @MainActor (McpSignInStep, Outcome) -> Void = { _, _ in }) {
        self.steps = steps
        self.makeFlow = makeFlow
        self.onStepFinished = onStepFinished
    }

    var current: McpSignInStep? { steps.indices.contains(index) && !isComplete ? steps[index] : nil }
    var hasNext: Bool { index + 1 < steps.count }
    var signedInCount: Int { outcomes.values.filter { $0 == .signedIn }.count }

    /// "Cloudflare" when every step is the same server, else nil.
    var singleServerName: String? {
        let names = Set(steps.map(\.serverName))
        return names.count == 1 ? names.first : nil
    }

    func outcome(of step: McpSignInStep) -> Outcome? { outcomes[step.id] }

    func start() {
        guard flow == nil, let step = current else { return }
        begin(step)
    }

    /// Starts the current step again with a fresh link.
    func retry() {
        guard let step = current else { return }
        Task {
            await flow?.stop()
            outcomes[step.id] = nil
            begin(step)
        }
    }

    /// Leaves the current step (stopping its sign-in) and moves on.
    func skip() {
        guard let step = current else { return }
        Task {
            if let flow, !flow.phase.isFinished { outcomes[step.id] = .skipped }
            await flow?.stop()
            if outcomes[step.id] == nil { outcomes[step.id] = .skipped }
            await advance()
        }
    }

    /// Moves on after a step that needs no more input (a connector link, a failure the user accepted).
    func next() {
        Task { await advance() }
    }

    func cancel() {
        flow?.cancel()
        isComplete = true
    }

    private func begin(_ step: McpSignInStep) {
        let flow = makeFlow(step)
        flow.onFinish = { [weak self, weak flow] phase in
            guard let self, let flow, self.flow === flow else { return }
            self.stepFinished(step, phase: phase)
        }
        self.flow = flow
        flow.start()
    }

    private func stepFinished(_ step: McpSignInStep, phase: McpLoginFlow.Phase) {
        let outcome: Outcome? = switch phase {
        case .succeeded: .signedIn
        case .finishOnClaudeAI: .finishOnClaudeAI
        case .failed, .expired: .failed
        case .cancelled: nil
        default: nil
        }
        guard let outcome else { return }
        outcomes[step.id] = outcome
        onStepFinished(step, outcome)
        if outcome == .signedIn {
            Task {
                try? await Task.sleep(for: Self.advanceDelay)
                guard self.current == step, self.outcomes[step.id] == .signedIn else { return }
                await self.advance()
            }
        }
    }

    private func advance() async {
        guard !advancing, !isComplete else { return }
        advancing = true
        defer { advancing = false }
        await flow?.stop()
        if hasNext {
            index += 1
            if let step = current { begin(step) }
        } else {
            isComplete = true
        }
    }
}
