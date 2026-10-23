import Foundation

/// Spots saved sign-in details that are out of date. Claude Pool names a profile's account from
/// Claude Code's saved copy (`oauthAccount` in `.claude.json`), which can lag behind the account
/// the profile really signs in with. One account has one 5-hour and one weekly window, so two
/// profiles that name the same account but report windows resetting at different times are using
/// different accounts.
enum AccountMismatch {
    /// Reset times closer than this are the same window (as in the collector).
    static let tolerance: TimeInterval = 60

    /// True when both report a window of the same kind that is still open, resetting at different times.
    static func windowsDisagree(_ a: UsageSnapshot?, _ b: UsageSnapshot?, now: Date) -> Bool {
        guard let a, let b else { return false }
        for (mine, theirs) in [(a.fiveHour, b.fiveHour), (a.sevenDay, b.sevenDay)] {
            guard let mine, let theirs, mine.resetsAt > now, theirs.resetsAt > now else { continue }
            if abs(mine.resetsAt.timeIntervalSince(theirs.resetsAt)) >= tolerance { return true }
        }
        return false
    }
}
