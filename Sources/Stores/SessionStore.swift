import Foundation
import Observation

/// A conversation being moved to another profile, and whether Claude Code confirmed it.
struct SessionHandoff: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        /// Terminal launched; waiting for Claude Code to register the resumed session.
        case pending
        /// The resumed session is running under the target profile (seen in its session registry).
        case confirmed(pid: Int32)
        /// Not seen within the time limit; the Terminal window shows why (e.g. trust prompt, error).
        case unconfirmed
    }

    let id = UUID()
    let sessionID: String
    let cwd: String
    let sourceProfileID: UUID
    let sourcePID: Int32
    let targetProfileID: UUID
    let startedAt: Date
    var state: State
}

/// Running Claude Code sessions per profile, refreshed by polling Claude Code's own registry.
@MainActor
@Observable
final class SessionStore {
    static let pollInterval: TimeInterval = 5
    static let confirmationTimeout: TimeInterval = 120

    private(set) var sessions: [ClaudeSession] = []
    private(set) var handoffs: [SessionHandoff] = []
    private(set) var lastRefresh: Date?

    @ObservationIgnored let registry: SessionRegistryService
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var profilesProvider: () -> [Profile] = { [] }
    @ObservationIgnored var onRefresh: (() -> Void)?

    init(registry: SessionRegistryService = SessionRegistryService()) {
        self.registry = registry
    }

    func start(profiles: @escaping () -> [Profile]) {
        profilesProvider = profiles
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(now: Date = Date()) {
        let profiles = profilesProvider()
        let latest = registry.sessions(for: profiles)
        if latest != sessions { sessions = latest }
        updateHandoffs(now: now)
        lastRefresh = now
        onRefresh?()
    }

    func sessions(for profileID: UUID) -> [ClaudeSession] {
        sessions.filter { $0.profileID == profileID }
    }

    /// Live sessions that run on a different profile than `activeID` (they keep their account).
    func sessions(notOn activeID: UUID?) -> [ClaudeSession] {
        guard let activeID else { return sessions }
        return sessions.filter { $0.profileID != activeID }
    }

    func handoff(for session: ClaudeSession) -> SessionHandoff? {
        handoffs.last { $0.sourcePID == session.pid && $0.sourceProfileID == session.profileID }
    }

    func beginHandoff(_ session: ClaudeSession, to target: UUID, now: Date = Date()) {
        handoffs.removeAll { $0.sessionID == session.sessionID && $0.state != .pending }
        handoffs.append(SessionHandoff(sessionID: session.sessionID, cwd: session.cwd, sourceProfileID: session.profileID,
                                       sourcePID: session.pid, targetProfileID: target, startedAt: now, state: .pending))
        refresh(now: now)
    }

    func dismissHandoff(_ id: UUID) {
        handoffs.removeAll { $0.id == id }
    }

    /// Confirmation requires Claude Code itself to register the resumed session under the target
    /// profile's directory: same session ID, or (if Claude Code assigned a new ID) a session in the
    /// same folder that started after the handoff.
    private func updateHandoffs(now: Date) {
        guard !handoffs.isEmpty else { return }
        var updated = handoffs
        for index in updated.indices where updated[index].state == .pending {
            let handoff = updated[index]
            let match = sessions.first { session in
                session.profileID == handoff.targetProfileID && session.pid != handoff.sourcePID && (
                    session.sessionID == handoff.sessionID ||
                    (session.cwd == handoff.cwd && (session.startedAt ?? .distantPast) >= handoff.startedAt.addingTimeInterval(-2))
                )
            }
            if let match {
                updated[index].state = .confirmed(pid: match.pid)
            } else if now.timeIntervalSince(handoff.startedAt) > Self.confirmationTimeout {
                updated[index].state = .unconfirmed
            }
        }
        if updated != handoffs { handoffs = updated }
    }
}
