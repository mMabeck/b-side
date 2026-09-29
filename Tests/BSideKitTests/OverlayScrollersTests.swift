import AppKit
import SwiftUI
import Testing
@testable import BSideKit

@MainActor
@Suite("Overlay scrollers")
struct OverlayScrollersTests {
    @Test("A sidebar List gets overlay scrollers even when the system prefers legacy ones")
    func listUsesOverlayScrollers() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: List(0..<100, id: \.self) { Text("Row \($0)") }
                .listStyle(.sidebar)
                .overlayScrollers()
        )
        window.setIsVisible(true)
        defer { window.orderOut(nil) }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        let deadline = Date().addingTimeInterval(5)
        var styles: [NSScroller.Style] = []
        while Date() < deadline {
            styles = scrollViews(in: window.contentView!).map(\.scrollerStyle)
            if !styles.isEmpty, styles.allSatisfy({ $0 == .overlay }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!styles.isEmpty)
        #expect(styles.allSatisfy { $0 == .overlay })
    }
}
