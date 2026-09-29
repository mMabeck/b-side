import AppKit
import Testing
@testable import BSideKit

@MainActor
@Suite("CommandWindowRouting")
struct CommandWindowRoutingTests {
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
        var terminalClosed = false
        var sheetDismissed = false
        let taskWindow = makeWindow()
        let settingsWindow = makeWindow()
        let sheet = makeWindow()
        CommandWindowRouting.setSheetCloseAction({ sheetDismissed = true }, for: sheet)
        taskWindow.setIsVisible(true)
        settingsWindow.setIsVisible(true)
        taskWindow.beginSheet(sheet, completionHandler: nil)
        defer {
            taskWindow.endSheet(sheet)
            taskWindow.orderOut(nil)
        }

        CommandWindowRouting.close(sheet, isTaskWindow: true) { terminalClosed = true }
        #expect(sheetDismissed)
        #expect(!terminalClosed)

        CommandWindowRouting.close(settingsWindow, isTaskWindow: false) { terminalClosed = true }
        #expect(!settingsWindow.isVisible)
        #expect(!terminalClosed)

        CommandWindowRouting.close(taskWindow, isTaskWindow: true) { terminalClosed = true }
        #expect(terminalClosed)
        #expect(taskWindow.isVisible)
    }
}
