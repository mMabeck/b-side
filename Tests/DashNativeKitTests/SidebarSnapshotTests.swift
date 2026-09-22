import AppKit
import Foundation
import GhosttyTheme
import SwiftUI
import Testing

@testable import DashNativeKit

/// Renders the left sidebar offscreen, populated with two projects (one
/// collapsed, one expanded with tasks in different states), and samples real
/// pixels inside the sidebar region. No layers are hidden before sampling:
/// this is the check the previous snapshot test skipped by excluding the
/// system's translucent chrome from the measurement (see
/// `ContentViewThemeSnapshotTests`). A real, never-key, never-onscreen
/// `NSWindow` driven only by programmatic APIs — no synthetic clicks or
/// keystrokes.
@MainActor
struct SidebarSnapshotTests {
    @Test("The populated sidebar samples as the palette's opaque surface colour, not system chrome")
    func sidebarIsOpaquelyThemed() async throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-native-sidebar-test-\(UUID().uuidString)")
        let ghosttyConfigDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: ghosttyConfigDir, withIntermediateDirectories: true)
        try "theme = Ayu Mirage\n".write(
            to: ghosttyConfigDir.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        let previousXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", configHome.path, 1)
        defer {
            if let previousXDG {
                setenv("XDG_CONFIG_HOME", previousXDG, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            try? FileManager.default.removeItem(at: configHome)
        }

        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        let expectedPalette = DashPalette.themed(from: ayuMirage)
        let expectedSurface = NSColor(expectedPalette.surfaceBackground)

        UserDefaults.standard.set(false, forKey: "leftSidebarCollapsed")
        UserDefaults.standard.set(true, forKey: "rightSidebarCollapsed")
        UserDefaults.standard.set(true, forKey: "terminalDrawerCollapsed")

        let workDir = configHome.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try await runGit(["init", "-b", "main"], in: workDir)
        try await runGit(["config", "user.email", "test@example.com"], in: workDir)
        try await runGit(["config", "user.name", "Test"], in: workDir)
        try "hello".write(to: workDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await runGit(["add", "."], in: workDir)
        try await runGit(["commit", "-m", "initial"], in: workDir)
        try await runGit(["branch", "feature/merged"], in: workDir) // == HEAD, trivially merged
        try "more".write(to: workDir.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        try await runGit(["checkout", "-b", "feature/ahead"], in: workDir)
        try await runGit(["add", "."], in: workDir)
        try await runGit(["commit", "-m", "ahead"], in: workDir)
        try await runGit(["checkout", "main"], in: workDir)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let collapsedWorkDir = configHome.appendingPathComponent("other-repo")
        try FileManager.default.createDirectory(at: collapsedWorkDir, withIntermediateDirectories: true)
        try await runGit(["init", "-b", "main"], in: collapsedWorkDir)

        let expandedProject = Project(path: workDir.path, displayName: "dash-native", baseRef: "main")
        let collapsedProject = Project(path: collapsedWorkDir.path, displayName: "dotfiles", baseRef: "main")

        let ids: (expandedProjectID: Int64, collapsedProjectID: Int64, finishedTaskID: Int64, attentionTaskID: Int64, runningTaskID: Int64, idleTaskID: Int64) = try await database.dbQueue.write { db in
            var expanded = expandedProject
            try expanded.insert(db)
            let expandedProjectID = expanded.id!

            var collapsed = collapsedProject
            try collapsed.insert(db)
            let collapsedProjectID = collapsed.id!

            var finished = TaskRecord(
                projectId: expandedProjectID, name: "Ship the release", branchName: "feature/merged",
                worktreePath: workDir.path, harness: "claude", permissionLevel: "default"
            )
            try finished.insert(db)

            var attention = TaskRecord(
                projectId: expandedProjectID, name: "Fix the login bug", branchName: "feature/ahead",
                worktreePath: workDir.path, harness: "claude", permissionLevel: "default"
            )
            try attention.insert(db)

            var running = TaskRecord(
                projectId: expandedProjectID, name: "Refactor the parser", branchName: "feature/ahead",
                worktreePath: workDir.path, harness: "claude", permissionLevel: "default"
            )
            try running.insert(db)

            var idle = TaskRecord(
                projectId: expandedProjectID, name: "Write docs", branchName: "main",
                worktreePath: workDir.path, harness: "claude", permissionLevel: "default"
            )
            try idle.insert(db)

            var collapsedTask = TaskRecord(
                projectId: collapsedProjectID, name: "Hidden while collapsed", branchName: "main",
                worktreePath: collapsedWorkDir.path, harness: "claude", permissionLevel: "default"
            )
            try collapsedTask.insert(db)

            return (expandedProjectID, collapsedProjectID, finished.id!, attention.id!, running.id!, idle.id!)
        }
        let expandedProjectID = ids.expandedProjectID
        let collapsedProjectID = ids.collapsedProjectID
        let finishedTaskID = ids.finishedTaskID
        let attentionTaskID = ids.attentionTaskID
        let runningTaskID = ids.runningTaskID
        let idleTaskID = ids.idleTaskID

        store.subagentFeed.beginRun(taskId: attentionTaskID, childId: "blocked-child", agent: "explorer", taskLabel: "Investigate")
        store.subagentFeed.ingest(
            taskId: attentionTaskID,
            childId: "blocked-child",
            event: .messageEnd(
                role: "assistant", stopReason: nil, errorMessage: nil,
                toolCalls: [SubagentToolCall(id: "t1", name: "question", arguments: [:])], text: nil
            )
        )
        store.subagentFeed.beginRun(taskId: runningTaskID, childId: "active-child", agent: "builder", taskLabel: "Working")

        UserDefaults.standard.set(
            SidebarCollapseState(collapsedProjectIDs: [collapsedProjectID]).rawValue,
            forKey: "sidebarCollapsedProjectIDs"
        )

        store.start()
        try await Task.sleep(for: .milliseconds(300))
        for taskID in [finishedTaskID, attentionTaskID, runningTaskID, idleTaskID] {
            let task = try #require(store.tasksByProject[expandedProjectID]?.first { $0.id == taskID })
            await store.refreshSyncStatus(for: task, project: expandedProject)
        }
        try await Task.sleep(for: .milliseconds(100))

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 340, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.setIsVisible(true)
        try await Task.sleep(for: .milliseconds(600))

        guard let contentView = window.contentView else {
            Issue.record("Window has no content view to render")
            return
        }
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Captured via `CGWindowListCreateImage`, not a manual `NSView`
        // draw pass: a manual `bitmapImageRepForCachingDisplay` +
        // `displayIgnoringOpacity` capture (as used by
        // `ContentViewThemeSnapshotTests`) only walks the `drawRect`-based
        // rendering path and silently produces a blank image for `List`'s
        // per-row `NSHostingView`s, which are only ever actually painted by
        // WindowServer's real compositor — confirmed by dumping the row view
        // hierarchy (frames and row counts were correct; the manual capture
        // still came back empty). Asking WindowServer directly for this
        // window's own composited pixels is the only capture path that
        // reflects what real rendering actually produced. The window is
        // still positioned off any physical display and never key/frontmost,
        // so nothing is shown to the user; no layers are hidden before
        // sampling — see `ContentViewThemeSnapshotTests`.
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else {
            Issue.record("Failed to capture window image")
            window.orderOut(nil)
            return
        }
        window.orderOut(nil)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: "/tmp/dash-native-sidebar.png"))

        let windowFrame = window.frame
        let scaleX = CGFloat(bitmap.pixelsWide) / windowFrame.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / windowFrame.height
        func sample(atPointX x: CGFloat, appKitY y: CGFloat) -> NSColor? {
            let pixelX = Int(x * scaleX)
            let pixelY = bitmap.pixelsHigh - Int(y * scaleY) - 1
            guard pixelX >= 0, pixelX < bitmap.pixelsWide, pixelY >= 0, pixelY < bitmap.pixelsHigh else { return nil }
            return bitmap.colorAt(x: pixelX, y: pixelY)
        }

        let contentFrame = contentView.frame
        // Sample multiple points down the sidebar column — between rows and
        // behind row content — so a themed background that's only partially
        // opaque (e.g. only under text) doesn't slip through.
        let sidebarSampleX = contentFrame.minX + 30
        let sampleYs: [CGFloat] = [0.15, 0.35, 0.55, 0.75, 0.92].map { contentFrame.minY + contentFrame.height * $0 }
        let samples = sampleYs.compactMap { sample(atPointX: sidebarSampleX, appKitY: $0) }
        #expect(samples.count == sampleYs.count, "Failed to sample all sidebar probe points")

        func report(_ label: String, _ color: NSColor) -> String {
            let c = color.usingColorSpace(.deviceRGB) ?? color
            return "\(label): r=\(c.redComponent) g=\(c.greenComponent) b=\(c.blueComponent)"
        }
        let expected = expectedSurface.usingColorSpace(.deviceRGB) ?? expectedSurface
        print(([report("expectedSurface", expectedSurface)] + samples.enumerated().map { report("sidebar[\($0.offset)]", $0.element) }).joined(separator: " | "))

        for color in samples {
            let c = color.usingColorSpace(.deviceRGB) ?? color
            // Genuinely opaque and themed means close to the palette's own
            // surface colour — not white, not an unrelated system grey.
            let isCloseToThemedSurface = abs(c.redComponent - expected.redComponent) < 0.2
                && abs(c.greenComponent - expected.greenComponent) < 0.2
                && abs(c.blueComponent - expected.blueComponent) < 0.2
            #expect(isCloseToThemedSurface, "Sidebar pixel \(report("", color)) is not close to the themed surface colour \(report("", expectedSurface))")
        }
    }
}

private func runGit(_ arguments: [String], in directory: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
}
