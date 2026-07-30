import AppKit
import Foundation
import UserNotifications

public final class UserNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var authorizationRequested = false

    /// UNUserNotificationCenter crashes when the process has no app bundle
    /// (e.g. a bare executable launched via `swift run`). Skip notifications
    /// in that environment.
    private static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static let filePathKey = "downloadedFilePath"

    public override init() {
        super.init()
        if Self.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    public func prepareAuthorization() {
        guard Self.isAvailable else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    public func notify(title: String, body: String = "", fileURL: URL? = nil) {
        guard Self.isAvailable else { return }

        prepareAuthorization()
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let fileURL {
            content.userInfo[Self.filePathKey] = fileURL.path
        }

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

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let path = response.notification.request.content.userInfo[Self.filePathKey] as? String else {
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            notify(
                title: NSLocalizedString("Downloaded File Unavailable", bundle: .main, comment: "Notification title"),
                body: NSLocalizedString("The downloaded file was moved or deleted.", bundle: .main, comment: "Notification body")
            )
            return
        }
        NSWorkspace.shared.open(fileURL)
    }
}
