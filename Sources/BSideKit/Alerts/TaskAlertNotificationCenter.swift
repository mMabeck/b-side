import AppKit
import UserNotifications

/// `UNUserNotificationCenter` needs a real bundle identifier (absent under `swift run`/`swift test`), so every entry point is guarded by `isSupported`.
@MainActor
public final class TaskAlertNotificationCenter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    public static let shared = TaskAlertNotificationCenter()

    public var onSelectTask: ((Int64) -> Void)?

    private var didRequestAuthorization = false

    public static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    public func activateIfSupported() {
        guard Self.isSupported else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    public func notify(taskID: Int64, taskName: String, title: String, body: String) {
        guard Self.isSupported else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "\(taskName) — \(title)"
        content.body = body
        // `TaskAlertSoundPlayer` already played the sound; a system one too would double it.
        content.sound = nil
        content.userInfo = ["taskID": taskID]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let taskID = response.notification.request.content.userInfo["taskID"] as? Int64 {
            onSelectTask?(taskID)
        }
        completionHandler()
    }

    /// Always present once posted: `ProjectsStore.handleTerminalAlert` already decides whether to post.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
