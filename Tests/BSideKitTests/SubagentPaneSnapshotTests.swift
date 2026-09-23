import AppKit
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

/// Renders a task's terminal area offscreen with a parent host and two
/// child subagent panes, using the real split layout `MainAreaView` drives
/// (native-rewrite.md §"The chosen design: native splits, plus cards").
/// Same offscreen-window-and-sample technique as `SubagentCardSnapshotTests`.
@MainActor
struct SubagentPaneSnapshotTests {
    @Test("Task area renders parent + child panes as a native horizontal split")
    func rendersParentAndChildPanes() async throws {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let theme = GhosttyResolvedTheme.shared
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        theme.update(ayuMirage)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-pane-snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let parentHost = TerminalSurfaceHost(workingDirectory: dir, shell: "/bin/zsh")
        store.subagentPanes.spawn(taskId: 1, childId: "c1", label: "explorer: map callers", cwd: dir, command: "/bin/sh")
        store.subagentPanes.spawn(taskId: 1, childId: "c2", label: "builder: add retry logic", cwd: dir, command: "/bin/sh")
        store.subagentFeed.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.subagentFeed.beginRun(taskId: 1, childId: "c2", agent: "builder", taskLabel: "Add retry logic")

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
        try await Task.sleep(for: .milliseconds(800))
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

        let outputPath = "/tmp/bside-subagent-panes.png"
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: outputPath))

        #expect(store.subagentPanes.panes(forTask: 1).count == 2)
    }
}

/// Mounts `TaskTerminalAreaView` the way `MainAreaView` does: a real
/// `@FocusState` and a per-task focused-child binding, since both are
/// required parameters `TaskTerminalAreaView` cannot be given without a
/// hosting `View`.
private struct TaskAreaHarness: View {
    var store: ProjectsStore
    var host: TerminalSurfaceHost
    var taskID: Int64
    @FocusState private var focusedTaskID: Int64?
    @State private var focusedChildID: String?

    var body: some View {
        TaskTerminalAreaView(
            store: store,
            host: host,
            taskID: taskID,
            focusedTaskID: $focusedTaskID,
            focusedChildID: $focusedChildID
        )
    }
}
