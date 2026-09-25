import AppKit
import SwiftUI
import Testing
@testable import BSideKit

@MainActor
struct TerminalScrollRouterTests {
    @Test func findsTerminalUnderPointOnly() async throws {
        let host = TerminalSurfaceHost(workingDirectory: FileManager.default.temporaryDirectory, shell: "/bin/zsh")
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: VStack(spacing: 0) {
                TerminalHostView(host: host).frame(height: 200)
                Color.clear.frame(height: 100)
            }
        )
        window.setIsVisible(true)
        defer { window.orderOut(nil) }

        // Window coordinates are bottom-up: the terminal fills the top 200pt.
        let deadline = Date().addingTimeInterval(5)
        while TerminalScrollRouter.terminalView(in: window, at: NSPoint(x: 200, y: 200)) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(TerminalScrollRouter.terminalView(in: window, at: NSPoint(x: 200, y: 200)) != nil)
        #expect(TerminalScrollRouter.terminalView(in: window, at: NSPoint(x: 200, y: 50)) == nil)
    }

    @Test func ignoresLineBasedWheelEvents() throws {
        let cgEvent = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)
        )
        let event = try #require(NSEvent(cgEvent: cgEvent))
        #expect(!event.hasPreciseScrollingDeltas)
        #expect(!TerminalScrollRouter.route(event))
    }

    @Test func mapsMomentumPhases() {
        #expect(TerminalScrollRouter.momentum(for: .began) == .began)
        #expect(TerminalScrollRouter.momentum(for: .changed) == .changed)
        #expect(TerminalScrollRouter.momentum(for: .stationary) == .stationary)
        #expect(TerminalScrollRouter.momentum(for: .ended) == .none)
        #expect(TerminalScrollRouter.momentum(for: []) == .none)
    }
}
