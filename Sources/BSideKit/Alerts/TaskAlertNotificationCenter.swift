import AppKit
import UserNotifications

/// Posts native macOS notifications for task alerts and routes clicks back
/// to the task that raised them.
///
/// `UNUserNotificationCenter` requires a bundled app (a real
/// `Bundle.main.bundleIdentifier`) — the bare `swift run`/`swift test`
/// binary has none, and `UNUserNotificationCenter.current()` crashes there.
/// Every entry point below is guarded by `isSupported` so this stays a
/// silent no-op in that environment instead of taking the process down.
@MainActor
public final class TaskAlertNotificationCenter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    public static let shared = TaskAlertNotificationCenter()

    /// Set by `ProjectsStore.start()` so a clicked notification can select
    /// its task. `nil` in contexts (tests, a store that never called
    /// `start()`) with nothing to route to.
    public var onSelectTask: ((Int64) -> Void)?

    private var didRequestAuthorization = false

    public static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Registers this instance as `UNUserNotificationCenter`'s delegate so
    /// `didReceive`/`willPresent` below actually fire. Safe to call more than
    /// once. No-op when `isSupported` is false.
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
        // Our own `TaskAlertSoundPlayer` already played the configured
        // sound for this alert; a system notification sound too would
        // double it.
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

    /// Shows the notification even while B-Side is the frontmost app —
    /// `ProjectsStore` already decides whether a notification should be
    /// posted at all (see `handleTerminalAlert`'s frontmost/selected check),
    /// so once one is posted it should always present, not be silently
    /// dropped by `UNUserNotificationCenter`'s own foreground suppression.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
