import Foundation
import UserNotifications

public final class UserNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var authorizationRequested = false

    public override init() {}

    public func prepareAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    public func notify(title: String, body: String = "") {
        prepareAuthorization()
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.list, .banner, .sound])
    }
}
