import AppKit
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

/// Renders the populated Subagents tab offscreen and samples pixels to
/// confirm the user's resolved Ghostty theme actually drives card colour.
/// Uses a real, never-ordered-front `NSWindow` (see `TerminalSurfaceHostTests`)
/// driven only by programmatic APIs — no synthetic clicks or keystrokes.
@MainActor
struct SubagentCardSnapshotTests {
    @Test("Populated Subagents tab renders with the resolved theme's colours")
    func rendersWithThemeColours() async throws {
        let theme = GhosttyResolvedTheme()
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        theme.update(ayuMirage)

        let active = ChildRun(id: "active", taskId: 1, agent: "explorer", taskLabel: "Map cache callers", openingLine: "Find every caller of the cache key builder.")
        var activeRun = active
        activeRun.toolLines = ["search /cacheKey/", "read src/cache/store.ts", "read src/cache/index.ts", "search invalidate(", "read src/api/handlers.ts", "bash rg -n cacheKey src"]
        activeRun.latestAssistantText = "Two call sites build the key by hand; checking whether the handlers share the same prefix."
        activeRun.statistics = RunStatistics(turns: 5, input: 40, output: 1200, contextTokens: 21000, model: "claude-opus-5")

        var blockedRun = ChildRun(id: "blocked", taskId: 1, agent: "builder", taskLabel: "Add retry logic", openingLine: "Retry transient failures.")
        blockedRun.toolLines = ["read src/net/client.ts"]
        blockedRun.state = .blocked

        var finishedRun = ChildRun(id: "finished", taskId: 1, agent: "reviewer", taskLabel: "Audit recent commits", openingLine: "Check the last three commits.")
        finishedRun.toolLines = ["bash git log -3", "read CHANGELOG.md", "bash git diff HEAD~3 --stat"]
        finishedRun.latestAssistantText = "LGTM with nits: one stale comment in store.ts."
        finishedRun.state = .completed
        finishedRun.statistics = RunStatistics(turns: 4, input: 120, output: 900, contextTokens: 8000, model: "claude-bridge/claude-sonnet-5")

        let content = VStack(alignment: .leading, spacing: 14) {
            SubagentCardView(run: activeRun, theme: theme)
            SubagentCardView(run: blockedRun, theme: theme)
            SubagentCardView(run: finishedRun, theme: theme)
        }
        .padding(14)
        .frame(width: 300)
        .background(theme.palette.windowBackground)

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 320, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Themed explicitly, as `themedWindow` does in production, so this
        // capture does not silently depend on whichever suite last set the
        // process-global `NSApp.appearance`.
        window.appearance = theme.palette.preferredAppearance
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 900)
        window.contentView = hostingView
        window.setIsVisible(true)
        try await Task.sleep(for: .milliseconds(300))
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            Issue.record("Failed to create bitmap representation")
            window.orderOut(nil)
            return
        }
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        hostingView.displayIgnoringOpacity(hostingView.bounds, in: graphicsContext)
        NSGraphicsContext.restoreGraphicsState()
        window.orderOut(nil)

        let outputPath = "/tmp/bside-subagent-cards.png"
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: outputPath))

        // Sample the background near the top-left corner: should match the
        // theme's resolved background, not a SwiftUI system default.
        let expectedBackground = NSColor(theme.palette.windowBackground)
        let sampled = try #require(bitmap.colorAt(x: 2, y: bitmap.pixelsHigh - 2))
        #expect(colorsAreClose(sampled, expectedBackground))
    }

    private func colorsAreClose(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 0.15) -> Bool {
        guard let a = a.usingColorSpace(.deviceRGB), let b = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }
}
