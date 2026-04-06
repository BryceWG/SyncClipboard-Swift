import Foundation
import UserNotifications

public final class UserNotifier {
    private var authorizationRequested = false

    public init() {}

    public func notify(title: String, body: String = "") {
        let center = UNUserNotificationCenter.current()

        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

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
}
