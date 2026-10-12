import Foundation
import Observation

/// Sign-in state per profile from `claude auth status`. In memory only.
@MainActor
@Observable
final class AuthStore {
    static let activationThrottle: TimeInterval = 60
    static let postSignInDelay: Duration = .seconds(30)

    private(set) var statuses: [UUID: AuthStatus] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var refreshing: Set<UUID> = []
    /// Non-secret plan data Claude Code cached in `.claude.json`, re-read with each check.
    private(set) var details: [UUID: AccountDetails] = [:]

    let service: AuthStatusService
    @ObservationIgnored private var lastAttempt: [UUID: Date] = [:]
    @ObservationIgnored private var pendingSignInChecks: [UUID: Task<Void, Never>] = [:]

    init(service: AuthStatusService) {
        self.service = service
    }

    func status(for id: UUID) -> AuthStatus? { statuses[id] }

    /// The most specific plan the data supports (e.g. "Max 20x"), or nil when signed out/unknown.
    func plan(for id: UUID) -> SubscriptionPlan? {
        guard let status = statuses[id], status.signedIn, status.reportsUsage else { return nil }
        return SubscriptionPlan.resolve(subscriptionType: status.subscriptionType, details: details[id], signedInEmail: status.email)
    }

    /// Other profiles signed in to the same account and organisation as `id`.
    func duplicates(of id: UUID, among profiles: [Profile]) -> [Profile] {
        guard let mine = statuses[id], mine.signedIn else { return [] }
        return profiles.filter { other in
            guard other.id != id, let theirs = statuses[other.id], theirs.signedIn else { return false }
            return mine.isSameAccount(as: theirs) == true
        }
    }

    /// Cheap: reads `.claude.json` only, no subprocess. Keeps plan changes in sync between checks.
    func reloadDetails(_ profiles: [Profile]) {
        for profile in profiles {
            var value = AccountDetailsReader.read(profile, home: service.home)
            // Ignore the read timestamp so an unchanged file does not trigger a redraw.
            if let old = details[profile.id], value != nil { value?.readAt = old.readAt }
            if details[profile.id] != value { details[profile.id] = value }
        }
    }

    func refresh(_ profile: Profile, binary: ClaudeBinary?) async {
        guard let binary else {
            errors[profile.id] = "Claude Code binary not found."
            return
        }
        guard !refreshing.contains(profile.id) else { return }
        refreshing.insert(profile.id)
        lastAttempt[profile.id] = Date()
        defer { refreshing.remove(profile.id) }
        do {
            record(try await service.check(profile, binary: binary), for: profile.id)
            details[profile.id] = AccountDetailsReader.read(profile, home: service.home)
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

    /// On app activation: at most once per 60s per profile.
    func refreshIfStale(_ profiles: [Profile], binary: ClaudeBinary?, now: Date = Date()) async {
        let due = profiles.filter { profile in
            guard let last = lastAttempt[profile.id] else { return true }
            return now.timeIntervalSince(last) >= Self.activationThrottle
        }
        await refreshAll(due, binary: binary)
    }

    /// Re-checks 30 seconds after a Sign In launch.
    func scheduleCheckAfterSignIn(_ profile: Profile, binary: @escaping @MainActor () -> ClaudeBinary?) {
        pendingSignInChecks[profile.id]?.cancel()
        pendingSignInChecks[profile.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.postSignInDelay)
            guard !Task.isCancelled else { return }
            await self?.refresh(profile, binary: binary())
        }
    }

    func record(_ status: AuthStatus, for id: UUID) {
        statuses[id] = status
        errors[id] = nil
    }

    func forget(_ id: UUID) {
        statuses[id] = nil
        details[id] = nil
        errors[id] = nil
        pendingSignInChecks[id]?.cancel()
    }
}
