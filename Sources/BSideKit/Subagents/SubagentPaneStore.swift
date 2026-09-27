import Foundation

/// Owns each child's live `TerminalSurfaceHost` surface, keyed by the task
/// that spawned it.
///
/// Ordered per task, oldest first — the order the strip and the swap
/// shortcuts use.
@MainActor
@Observable
public final class SubagentPaneStore {
    /// Cap before the spawner falls back to headless for extra children —
    /// about memory/pty cost, not screen space, since only one surface is ever shown at a time.
    public static let maxPanesPerTask = 4

    public struct ChildPane: Identifiable, Sendable {
        public let id: String
        public let taskId: Int64
        public let label: String
        public let host: TerminalSurfaceHost
    }

    public private(set) var panesByTask: [Int64: [ChildPane]] = [:]

    /// Bumped on every mutation, since `panesByTask`'s reference-type hosts
    /// give no cheap `Equatable` diff to hang `.onChange` off of directly.
    public private(set) var version = 0

    /// Tests inject `TerminalSurfaceHost.makeInMemoryForTesting()`, since
    /// spawning many real exec surfaces back-to-back crashes libghostty under `swift test`.
    private let makeHost: (URL, String, @escaping (Bool) -> Void) -> TerminalSurfaceHost

    public init() {
        makeHost = { cwd, command, onExit in
            TerminalSurfaceHost(workingDirectory: cwd, command: command, onExit: onExit)
        }
    }

    init(makeHost: @escaping (URL, String, @escaping (Bool) -> Void) -> TerminalSurfaceHost) {
        self.makeHost = makeHost
    }

    public func panes(forTask taskId: Int64) -> [ChildPane] {
        panesByTask[taskId] ?? []
    }

    /// Idempotent for a `childId` already registered. `false` only when the
    /// task is already at `maxPanesPerTask`; the caller turns that into a `429`.
    @discardableResult
    public func spawn(taskId: Int64, childId: String, label: String, cwd: URL, command: String) -> Bool {
        var panes = panesByTask[taskId] ?? []
        guard !panes.contains(where: { $0.id == childId }) else { return true }
        guard panes.count < Self.maxPanesPerTask else { return false }

        // Starts not-visible: `MainAreaView.syncVisibility()` corrects this via `version` changing.
        let host = makeHost(cwd, command) { [weak self] _ in
            self?.close(taskId: taskId, childId: childId)
        }
        host.isVisible = false
        panes.append(ChildPane(id: childId, taskId: taskId, label: label, host: host))
        panesByTask[taskId] = panes
        version += 1
        return true
    }

    /// Idempotent — a second close, or one racing the surface's own process-exit teardown, is a no-op.
    public func close(taskId: Int64, childId: String) {
        guard var panes = panesByTask[taskId], let index = panes.firstIndex(where: { $0.id == childId }) else { return }
        panes.remove(at: index)
        panesByTask[taskId] = panes.isEmpty ? nil : panes
        version += 1
    }

    /// A child pane never outlives the parent terminal it belongs to.
    public func closeAll(taskId: Int64) {
        guard panesByTask.removeValue(forKey: taskId) != nil else { return }
        version += 1
    }
}
