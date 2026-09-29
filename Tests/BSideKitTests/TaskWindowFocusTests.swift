import AppKit
import Testing
@testable import BSideKit

@MainActor
@Suite("TaskWindowFocus")
struct TaskWindowFocusTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    @Test("only the task window and its sheets count as the task window being in front, not Settings")
    func roles() {
        let focus = TaskWindowFocus()
        let taskWindow = makeWindow()
        let settingsWindow = makeWindow()
        let sheet = makeWindow()
        focus.register(taskWindow)
        taskWindow.setIsVisible(true)
        taskWindow.beginSheet(sheet, completionHandler: nil)
        defer {
            taskWindow.endSheet(sheet)
            taskWindow.orderOut(nil)
            settingsWindow.orderOut(nil)
        }

        #expect(focus.role(of: taskWindow) == .task)
        #expect(focus.role(of: sheet) == .taskSheet)
        #expect(focus.role(of: settingsWindow) == .other)
        #expect(focus.role(of: nil) == .other)
    }
}
