import AppKit
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

/// Renders a task's real terminal area \u2014 the subagent strip (a real
/// in-memory Ghostty surface, not a mock) above the parent terminal \u2014 with
/// three runs (one active, one blocked, one finished) offscreen and saves a
/// PNG, same offscreen-window-and-sample technique
/// `RightSidebarSnapshotTests`/`SidebarSnapshotTests` use.
@MainActor
struct SubagentStripSnapshotTests {
    @Test("Task area renders the subagent strip above the parent terminal")
    func rendersStripAboveTerminal() async throws {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let theme = GhosttyResolvedTheme.shared
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        theme.update(ayuMirage)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-strip-snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let parentHost = TerminalSurfaceHost(workingDirectory: dir, shell: "/bin/zsh")

        store.subagentFeed.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.subagentFeed.ingest(
            taskId: 1, childId: "c1",
            event: .messageEnd(role: "assistant", stopReason: nil, errorMessage: nil, toolCalls: [
                .init(id: "t1", name: "search", arguments: ["pattern": .string("cacheKey")]),
            ], text: nil, usage: nil)
        )

        store.subagentFeed.beginRun(taskId: 1, childId: "c2", agent: "builder", taskLabel: "Add retry logic")
        store.subagentFeed.ingest(
            taskId: 1, childId: "c2",
            event: .messageEnd(role: "assistant", stopReason: nil, errorMessage: nil, toolCalls: [
                .init(id: "t2", name: "question", arguments: [:]),
            ], text: nil, usage: nil)
        )

        store.subagentFeed.beginRun(taskId: 1, childId: "c3", agent: "reviewer", taskLabel: "Audit recent commits")
        store.subagentFeed.markDone(taskId: 1, childId: "c3", payload: SubagentDonePayload(exitCode: 0, stopReason: nil, errorMessage: nil, statistics: nil))

        let content = TaskAreaHarness(store: store, host: parentHost, taskID: 1)
            .frame(width: 900, height: 500)
            .background(theme.palette.windowBackground)

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = theme.palette.preferredAppearance
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = hostingView
        window.setIsVisible(true)
        try await Task.sleep(for: .milliseconds(1200))
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

        let outputPath = "/tmp/bside-strip.png"
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: outputPath))

        #expect(store.subagentFeed.runs(forTask: 1).count == 3)
    }
}

/// Mounts `TaskTerminalAreaView` the way `MainAreaView` does: a real
/// `@FocusState`, since `TaskTerminalAreaView` cannot be given one without a
/// hosting `View`.
private struct TaskAreaHarness: View {
    var store: ProjectsStore
    var host: TerminalSurfaceHost
    var taskID: Int64
    @FocusState private var focusedTaskID: Int64?

    var body: some View {
        TaskTerminalAreaView(
            store: store,
            host: host,
            taskID: taskID,
            focusedTaskID: $focusedTaskID
        )
    }
}
