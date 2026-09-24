import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("SubagentPaneStore")
struct SubagentPaneStoreTests {
    private func fakeHostFactory(cwd: URL, command: String, onExit: @escaping (Bool) -> Void) -> TerminalSurfaceHost {
        TerminalSurfaceHost.makeInMemoryForTesting()
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-pane-store-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Spawning registers a pane and bumps version")
    func spawnRegistersPane() {
        let store = SubagentPaneStore()
        let created = store.spawn(taskId: 1, childId: "c1", label: "explorer: map callers", cwd: tempDir(), command: "/bin/sh")
        #expect(created)
        #expect(store.panes(forTask: 1).map(\.id) == ["c1"])
        #expect(store.version == 1)
    }

    @Test("Panes stay ordered oldest first as more spawn")
    func spawnOrdersOldestFirst() {
        let store = SubagentPaneStore()
        store.spawn(taskId: 1, childId: "c1", label: "a", cwd: tempDir(), command: "/bin/sh")
        store.spawn(taskId: 1, childId: "c2", label: "b", cwd: tempDir(), command: "/bin/sh")
        store.spawn(taskId: 1, childId: "c3", label: "c", cwd: tempDir(), command: "/bin/sh")
        #expect(store.panes(forTask: 1).map(\.id) == ["c1", "c2", "c3"])
    }

    @Test("Spawning an already-registered child id is a no-op, not a duplicate")
    func spawnIsIdempotentPerChildId() {
        let store = SubagentPaneStore()
        store.spawn(taskId: 1, childId: "c1", label: "a", cwd: tempDir(), command: "/bin/sh")
        let originalHost = store.panes(forTask: 1).first?.host
        let created = store.spawn(taskId: 1, childId: "c1", label: "a again", cwd: tempDir(), command: "/bin/sh")
        #expect(created)
        #expect(store.panes(forTask: 1).count == 1)
        #expect(store.panes(forTask: 1).first?.host === originalHost)
    }

    @Test("Spawning past the cap fails and does not register a pane")
    func spawnRespectsCap() {
        let store = SubagentPaneStore(makeHost: fakeHostFactory)
        for index in 0..<SubagentPaneStore.maxPanesPerTask {
            let created = store.spawn(taskId: 1, childId: "c\(index)", label: "child \(index)", cwd: tempDir(), command: "/bin/sh")
            #expect(created)
        }
        #expect(store.panes(forTask: 1).count == SubagentPaneStore.maxPanesPerTask)

        let overCap = store.spawn(taskId: 1, childId: "over-cap", label: "one too many", cwd: tempDir(), command: "/bin/sh")
        #expect(!overCap)
        #expect(store.panes(forTask: 1).count == SubagentPaneStore.maxPanesPerTask)
        #expect(!store.panes(forTask: 1).contains { $0.id == "over-cap" })
    }

    @Test("A closed task's cap frees up for a new child")
    func closingFreesCapSlot() {
        let store = SubagentPaneStore(makeHost: fakeHostFactory)
        for index in 0..<SubagentPaneStore.maxPanesPerTask {
            store.spawn(taskId: 1, childId: "c\(index)", label: "child \(index)", cwd: tempDir(), command: "/bin/sh")
        }
        store.close(taskId: 1, childId: "c0")
        #expect(store.panes(forTask: 1).map(\.id) == (1..<SubagentPaneStore.maxPanesPerTask).map { "c\($0)" })

        let created = store.spawn(taskId: 1, childId: "new", label: "new child", cwd: tempDir(), command: "/bin/sh")
        #expect(created)
        #expect(store.panes(forTask: 1).count == SubagentPaneStore.maxPanesPerTask)
    }

    @Test("Closing an unknown pane is a no-op")
    func closeUnknownPaneIsNoOp() {
        let store = SubagentPaneStore()
        store.spawn(taskId: 1, childId: "c1", label: "a", cwd: tempDir(), command: "/bin/sh")
        let versionBefore = store.version
        store.close(taskId: 1, childId: "does-not-exist")
        store.close(taskId: 99, childId: "c1")
        #expect(store.panes(forTask: 1).map(\.id) == ["c1"])
        #expect(store.version == versionBefore)
    }

    @Test("Closing the last pane for a task removes the task's empty entry")
    func closingLastPaneClearsTaskEntry() {
        let store = SubagentPaneStore()
        store.spawn(taskId: 1, childId: "c1", label: "a", cwd: tempDir(), command: "/bin/sh")
        store.close(taskId: 1, childId: "c1")
        #expect(store.panes(forTask: 1).isEmpty)
        #expect(store.panesByTask[1] == nil)
    }

    @Test("closeAll removes every pane for a task in one call")
    func closeAllRemovesEveryPane() {
        let store = SubagentPaneStore()
        store.spawn(taskId: 1, childId: "c1", label: "a", cwd: tempDir(), command: "/bin/sh")
        store.spawn(taskId: 1, childId: "c2", label: "b", cwd: tempDir(), command: "/bin/sh")
        store.spawn(taskId: 2, childId: "c3", label: "c", cwd: tempDir(), command: "/bin/sh")

        store.closeAll(taskId: 1)

        #expect(store.panes(forTask: 1).isEmpty)
        #expect(store.panes(forTask: 2).map(\.id) == ["c3"])
    }

    @Test("Spawned panes start not-visible")
    func spawnedPanesStartNotVisible() {
        let store = SubagentPaneStore()
        store.spawn(taskId: 1, childId: "c1", label: "a", cwd: tempDir(), command: "/bin/sh")
        #expect(store.panes(forTask: 1).first?.host.isVisible == false)
    }
}
