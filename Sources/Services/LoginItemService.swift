import Foundation
import ServiceManagement

/// Launch at login via SMAppService.mainApp. The state is always read back from the system.
@MainActor
struct LoginItemService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .notRegistered: "Off"
        case .requiresApproval: "Needs approval in System Settings › General › Login Items"
        case .notFound: "Unavailable for this copy of the app"
        @unknown default: "Unknown"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
