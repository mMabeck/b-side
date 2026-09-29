import AppKit
import Testing
@testable import BSideKit

@MainActor
@Suite("TaskWindowFocus")
struct TaskWindowFocusTests {
    private final class Flags {
        var terminalClosed = false
        var sheetDismissed = false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("Cmd+W ends the terminal only in the task window, dismisses a sheet, and closes Settings")
    func closeRouting() {
        let focus = TaskWindowFocus()
        let flags = Flags()
        let taskWindow = makeWindow()
        let settingsWindow = makeWindow()
        let sheet = makeWindow()
        focus.register(taskWindow)
        focus.setSheetCloseAction({ flags.sheetDismissed = true }, for: sheet)
        taskWindow.setIsVisible(true)
        settingsWindow.setIsVisible(true)
        taskWindow.beginSheet(sheet, completionHandler: nil)
        defer {
            taskWindow.endSheet(sheet)
            taskWindow.orderOut(nil)
        }
        #expect(focus.role(of: nil) == .other)

        focus.close(sheet) { flags.terminalClosed = true }
        #expect(flags.sheetDismissed)
        #expect(!flags.terminalClosed)

        focus.close(settingsWindow) { flags.terminalClosed = true }
        #expect(!settingsWindow.isVisible)
        #expect(!flags.terminalClosed)

        focus.close(taskWindow) { flags.terminalClosed = true }
        #expect(flags.terminalClosed)
        #expect(taskWindow.isVisible)
    }
}
