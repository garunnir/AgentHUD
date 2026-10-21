import Foundation
import UserNotifications

/// userInfo key carrying the session ID (file-level so the nonisolated delegate can read it).
private let sessionKey = "sessionId"

/// Usage-limit reset banners through Notification Center; clicking one opens the session.
/// UNUserNotificationCenter needs a real app bundle (it traps under `swift run`), so it is
/// only used when the process has a bundle identifier (AgentHud.app from build_app.sh).
@MainActor
final class LimitResetNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (@MainActor (String) -> Void)?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { print("Notification authorization: \(error)") }
        }
    }

    func show(sessionId: String, title: String, body: String) {
        guard let center else { return }
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [sessionKey: sessionId]
        center.add(UNNotificationRequest(identifier: "limit-reset-\(sessionId)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo[sessionKey] as? String
        Task { @MainActor in
            if let id { self.onOpen?(id) }
        }
        completionHandler()
    }

    /// Show the banner even though the HUD is the frontmost (accessory) app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
