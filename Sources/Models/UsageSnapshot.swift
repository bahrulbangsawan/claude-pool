import Foundation
@_exported import PoolShared

/// The snapshot and window types live in `Shared/UsageSnapshot.swift` so the collector
/// writes exactly what the app reads. This file adds app-only conveniences.
enum UsageWindowKind: String, CaseIterable, Hashable, Sendable {
    case fiveHour
    case sevenDay

    var shortLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        }
    }

    var spokenLabel: String {
        switch self {
        case .fiveHour: "5-hour limit"
        case .sevenDay: "7-day limit"
        }
    }

    var title: String {
        switch self {
        case .fiveHour: "5-hour window"
        case .sevenDay: "7-day window"
        }
    }
}

extension UsageSnapshot {
    func window(_ kind: UsageWindowKind) -> UsageWindow? {
        switch kind {
        case .fiveHour: fiveHour
        case .sevenDay: sevenDay
        }
    }
}
