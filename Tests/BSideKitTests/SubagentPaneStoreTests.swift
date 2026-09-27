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

    @Test("Closing the last pane for a task removes the task's empty entry")
    func closingLastPaneClearsTaskEntry() {
        let store = SubagentPaneStore()
        store.spawn(taskId: 1, childId: "c1", label: "a", cwd: tempDir(), command: "/bin/sh")
        store.close(taskId: 1, childId: "c1")
        #expect(store.panes(forTask: 1).isEmpty)
        #expect(store.panesByTask[1] == nil)
    }
}
