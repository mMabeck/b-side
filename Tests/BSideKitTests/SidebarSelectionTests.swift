import AppKit
import SwiftUI
import Testing

@testable import BSideKit

/// Regression for a List-selection bug: `selectionBinding` used to re-derive its value from
/// `store.openTerminalTaskIDs`, so opening a terminal for the selected task silently moved the
/// highlight from the project row to the newly inserted Active row in the same table update.
@MainActor
@Suite("Sidebar selection stability")
struct SidebarSelectionTests {
    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let table = findTableView(in: sub) { return table }
        }
        return nil
    }

    private func makeStore() throws -> (ProjectsStore, AppDatabase) {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        store.playAlertSound = { _ in }
        return (store, database)
    }

    @Test("Selection stays put across programmatic selects, terminal opens, clicks, and activity bumps")
    func selectionStaysStable() async throws {
        let (store, database) = try makeStore()
        let (project, alpha, beta): (Project, TaskRecord, TaskRecord) = try await database.dbQueue.write { db in
            var project = Project(path: "/tmp/sidebar-sel-proj", displayName: "P", baseRef: "main")
            try project.insert(db)
            var alpha = TaskRecord(projectId: project.id!, name: "Alpha", branchName: "a", worktreePath: "/tmp/sel-a", harness: "claude", permissionLevel: "default", lastActivityAt: Date(timeIntervalSince1970: 100))
            try alpha.insert(db)
            var beta = TaskRecord(projectId: project.id!, name: "Beta", branchName: "b", worktreePath: "/tmp/sel-b", harness: "claude", permissionLevel: "default", lastActivityAt: Date(timeIntervalSince1970: 101))
            try beta.insert(db)
            return (project, alpha, beta)
        }
        store.start()
        defer { store.stop() }
        try await waitUntil { (store.tasksByProject[project.id!]?.count ?? 0) == 2 }

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 600),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: SidebarView(store: store))
        window.setIsVisible(true)
        try await waitUntil { self.findTableView(in: window.contentView!) != nil }
        let table = try #require(findTableView(in: window.contentView!))
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        // `List` renders a header row per `Section`, which occupies a real NSTableView row
        // index; `nil` marks those so selection lookups only ever match a real content row.
        func layout() -> [SidebarView.SidebarRowID?] {
            var rows: [SidebarView.SidebarRowID?] = []
            if !store.openTerminalTaskIDs.isEmpty {
                rows.append(nil)
                rows += store.openTerminalTaskIDs.map { .activeTask($0) }
            }
            rows.append(nil)
            rows.append(.project(project.id!))
            let tasks = store.tasksByProject[project.id!] ?? []
            rows += tasks.map { .task($0.id!) }
            return rows
        }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }

        func expectSelection(_ row: SidebarView.SidebarRowID, timeout: Duration = .seconds(2)) async throws {
            try await settle()
            let deadline = ContinuousClock.now + timeout
            var matched = false
            var lastRows: [Int] = []
            var lastSelectedViews: [Int] = []
            while ContinuousClock.now < deadline {
                let index = layout().firstIndex(where: { $0 == row })
                let selectedRows = Array(table.selectedRowIndexes)
                let selectedViews = (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: false)?.isSelected == true }
                lastRows = selectedRows
                lastSelectedViews = selectedViews
                if let index, selectedRows == [index], selectedViews == [index] {
                    matched = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(matched, "expected selection at \(row): selectedRows=\(lastRows) selectedViews=\(lastSelectedViews) layout=\(layout())")
        }

        func click(_ row: SidebarView.SidebarRowID) throws {
            let index = try #require(layout().firstIndex(where: { $0 == row }))
            table.selectRowIndexes([index], byExtendingSelection: false)
        }

        // (a) selecting a task with no open terminal, then opening one, must not move the
        // highlight off the row under the project.
        store.selectTask(alpha, project: project)
        try await expectSelection(.task(alpha.id!))
        store.noteTerminalOpened(taskID: alpha.id!)
        try await expectSelection(.task(alpha.id!))

        // (b) clicking a task row under its project while it already has an Active row keeps
        // the highlight under the project, including across activity reorders.
        store.noteTerminalOpened(taskID: beta.id!)
        try await settle()
        try click(.task(beta.id!))
        try await expectSelection(.task(beta.id!))
        store.bumpTaskActivity(alpha.id!)
        try await expectSelection(.task(beta.id!))
        store.bumpTaskActivity(beta.id!)
        try await expectSelection(.task(beta.id!))

        // (c) clicking the Active row keeps the highlight there across bumps.
        try click(.activeTask(beta.id!))
        try await expectSelection(.activeTask(beta.id!))
        store.bumpTaskActivity(alpha.id!)
        try await expectSelection(.activeTask(beta.id!))
        store.bumpTaskActivity(beta.id!)
        try await expectSelection(.activeTask(beta.id!))

        // (d) a programmatic select (⌘-digit style) of an already-open task highlights the
        // Active row directly.
        store.selectTask(alpha, project: project)
        try await expectSelection(.activeTask(alpha.id!))
    }
}
