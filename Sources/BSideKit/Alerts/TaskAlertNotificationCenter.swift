import AppKit
import UserNotifications

/// Posts native macOS notifications for task alerts and routes clicks back
/// to the task that raised them.
///
/// `UNUserNotificationCenter` requires a real `Bundle.main.bundleIdentifier`;
/// the bare `swift run`/`swift test` binary has none and would crash there.
/// Every entry point is guarded by `isSupported` to stay a silent no-op instead.
@MainActor
public final class TaskAlertNotificationCenter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    public static let shared = TaskAlertNotificationCenter()

    /// Set by `ProjectsStore.start()`; `nil` when there's nothing to route to.
    public var onSelectTask: ((Int64) -> Void)?

    private var didRequestAuthorization = false

    public static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Safe to call more than once.
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

    /// `ProjectsStore.handleTerminalAlert` already decides whether to post at
    /// all, so once posted it should always present, not be suppressed by the foreground default.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
