import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite struct ChangesOverlayStoreTests {
    @Test func foldersStartExpandedAndCollapseSurvivesRefresh() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repo = try await TestRepo.makeRepo(in: root)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src/ui"), withIntermediateDirectories: true)
        try "a\n".write(to: repo.appendingPathComponent("src/ui/a.swift"), atomically: true, encoding: .utf8)
        try "b\n".write(to: repo.appendingPathComponent("src/b.swift"), atomically: true, encoding: .utf8)

        let store = ChangesOverlayStore()
        store.present(task: TaskRecord(
            projectId: 1, name: "t", branchName: "main", branchCreatedByApp: false,
            worktreePath: repo.path, harness: "pi", permissionLevel: "default"
        ))
        defer { store.dismiss() }
        try await waitUntil { store.loadState == .loaded && !store.tree.isEmpty }
        #expect(store.collapsedFolderIDs.isEmpty)

        let expandedRowCount = store.visibleRows.count
        store.collapseAllFolders()
        let collapsed = store.collapsedFolderIDs
        #expect(!collapsed.isEmpty)
        #expect(store.visibleRows.count < expandedRowCount)

        await store.refresh()
        #expect(store.collapsedFolderIDs == collapsed)

        store.expandAllFolders()
        #expect(store.collapsedFolderIDs.isEmpty)
    }
}
