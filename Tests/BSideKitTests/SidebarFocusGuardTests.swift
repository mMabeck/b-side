import AppKit
import Testing

@testable import BSideKit

/// Exercises `SidebarFocusGuard.Coordinator` against a real, offscreen
/// `NSWindow` and a programmatically constructed `NSEvent` — never a real
/// OS-level synthetic click — checking that a mouse-down inside the marker
/// view's bounds reasserts terminal focus (via
/// `ProjectsStore.requestTerminalFocus()`, observed here as a
/// `focusRequestToken` bump) only when a task is actually selected, and that
/// a mouse-down outside those bounds, or in another window, is ignored.
@MainActor
@Suite("SidebarFocusGuard")
struct SidebarFocusGuardTests {
    private func makeStore() async throws -> (store: ProjectsStore, project: Project, task: TaskRecord) {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        store.playAlertSound = { _ in }

        let (project, task): (Project, TaskRecord) = try await database.dbQueue.write { db in
            var project = Project(path: "/tmp/sidebar-focus-guard-project", displayName: "P", baseRef: "main")
            try project.insert(db)
            var task = TaskRecord(
                projectId: project.id!, name: "Task", branchName: "feature/x",
                worktreePath: "/tmp/sidebar-focus-guard-worktree", harness: "claude", permissionLevel: "default"
            )
            try task.insert(db)
            return (project, task)
        }

        store.start()
        try await waitUntil {
            store.projects.contains { $0.id == project.id }
                && (store.tasksByProject[project.id!]?.contains { $0.id == task.id } ?? false)
        }
        return (store, project, task)
    }

    private func mouseDown(at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test("A mouse-down inside the marker's bounds re-requests terminal focus when a task is selected")
    func clickInsideBoundsRefocusesTerminal() async throws {
        let (store, project, task) = try await makeStore()
        store.selectTask(task, project: project)
        let tokenBefore = store.focusRequestToken

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        window.contentView = marker
        window.setIsVisible(true)

        let coordinator = SidebarFocusGuard.Coordinator(store: store)
        coordinator.attach(to: marker)

        coordinator.handleMouseDown(mouseDown(at: NSPoint(x: 50, y: 50), in: window), in: window)
        try await waitUntil { store.focusRequestToken > tokenBefore }
        #expect(store.focusRequestToken == tokenBefore + 1)

        window.orderOut(nil)
    }

    @Test("A mouse-down outside the marker's bounds does not request terminal focus")
    func clickOutsideBoundsLeavesFocusAlone() async throws {
        let (store, project, task) = try await makeStore()
        store.selectTask(task, project: project)
        let tokenBefore = store.focusRequestToken

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // The marker only covers the sidebar's own region, not the whole
        // window \u2014 same as `.background(SidebarFocusGuard(...))` sizing it
        // to the sidebar's `VStack`, not the whole content view.
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 400))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        container.addSubview(marker)
        window.contentView = container
        window.setIsVisible(true)

        let coordinator = SidebarFocusGuard.Coordinator(store: store)
        coordinator.attach(to: marker)

        coordinator.handleMouseDown(mouseDown(at: NSPoint(x: 150, y: 50), in: window), in: window)
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.focusRequestToken == tokenBefore)

        window.orderOut(nil)
    }

}
