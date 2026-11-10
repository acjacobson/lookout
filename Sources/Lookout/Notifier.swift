import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the session key when the user clicks a notification.
    var onOpen: ((String) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("Lookout: notification permission granted=\(granted) error=\(String(describing: error))")
        }
    }

    /// The UserDefaults key for the Notifications toggle in the gear menu.
    static let enabledKey = "notificationsEnabled"

    /// On unless turned off in the gear menu.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func post(_ s: Session) {
        guard Notifier.enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = s.state == .needsInput ? "\(s.agentName) needs a decision" : "\(s.agentName) is done"
        content.subtitle = [s.folder, s.displayTitle].compactMap { $0 }.uniqued().joined(separator: " · ")
        content.body = s.detail ?? ""
        content.sound = .default
        content.userInfo = ["key": s.id]
        // Same identifier per session, so a newer alert replaces the older one.
        center.add(UNNotificationRequest(identifier: s.id, content: content, trigger: nil)) { error in
            if let error { NSLog("Lookout: notification failed: \(error)") }
        }
    }

    func remove(_ key: String) {
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let key = response.notification.request.content.userInfo["key"] as? String {
            DispatchQueue.main.async { self.onOpen?(key) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
