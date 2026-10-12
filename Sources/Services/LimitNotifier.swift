import Foundation
import UserNotifications

/// Posts local macOS notifications for usage alerts. Needs the app bundle: when running unbundled
/// (tests, `swift run`) notifications are reported as unavailable and nothing is posted.
@MainActor
final class LimitNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Authorization: Equatable, Sendable {
        case unavailable
        case notDetermined
        case denied
        case allowed
    }

    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? { Self.isSupported ? .current() : nil }

    func activate() {
        center?.delegate = self
    }

    func authorization() async -> Authorization {
        guard let center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    /// Shows the system permission prompt the first time; afterwards returns the stored answer.
    func requestAuthorization() async -> Authorization {
        guard let center else { return .unavailable }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func post(id: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Menu bar apps count as frontmost while their panel is open; show the banner anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
