import Foundation

/// Owns each child's live `TerminalSurfaceHost` surface, keyed by the task
/// that spawned it.
///
/// Ordered per task, oldest first — the order the strip and the swap
/// shortcuts use.
@MainActor
@Observable
public final class SubagentPaneStore {
    /// Cap on live panes per task before the spawner is told to fall back to
    /// headless (card only) for extra children. The task's main area only
    /// ever shows one surface at a time (swap, not a split), so this cap is
    /// about how many child surfaces stay mounted — memory/pty cost, not
    /// screen space.
    public static let maxPanesPerTask = 4

    public struct ChildPane: Identifiable, Sendable {
        public let id: String
        public let taskId: Int64
        public let label: String
        public let host: TerminalSurfaceHost
    }

    public private(set) var panesByTask: [Int64: [ChildPane]] = [:]

    /// Bumped on every mutation. `panesByTask`'s values hold reference-type
    /// `TerminalSurfaceHost`s, so there is no cheap `Equatable` diff a caller
    /// could hang an `.onChange` off of directly — this mirrors
    /// `ProjectsStore.focusRequestToken`'s role for exactly that reason.
    public private(set) var version = 0

    /// Builds the `TerminalSurfaceHost` for a newly spawned child. Real
    /// callers get the production closure below (a real pty/Ghostty exec
    /// surface); tests inject `TerminalSurfaceHost.makeInMemoryForTesting()`
    /// instead, since spawning many real exec surfaces back-to-back (as the
    /// cap tests do) crashes libghostty under `swift test`.
    private let makeHost: (URL, String, @escaping (Bool) -> Void) -> TerminalSurfaceHost

    public init() {
        makeHost = { cwd, command, onExit in
            TerminalSurfaceHost(workingDirectory: cwd, command: command, onExit: onExit)
        }
    }

    init(makeHost: @escaping (URL, String, @escaping (Bool) -> Void) -> TerminalSurfaceHost) {
        self.makeHost = makeHost
    }

    /// Panes for `taskId`, oldest first.
    public func panes(forTask taskId: Int64) -> [ChildPane] {
        panesByTask[taskId] ?? []
    }

    /// Creates and registers a new child pane's surface, unless the task is
    /// already at the pane cap. Idempotent for a `childId` already
    /// registered: the existing pane (and its live surface) is left
    /// untouched rather than torn down and recreated.
    ///
    /// - Returns: `false` only when the task is already at
    ///   `maxPanesPerTask` and `childId` is not already one of its panes —
    ///   the caller (`SubagentEventServer`) turns that into a `429`, telling
    ///   the spawner to fall back to headless for this child.
    @discardableResult
    public func spawn(taskId: Int64, childId: String, label: String, cwd: URL, command: String) -> Bool {
        var panes = panesByTask[taskId] ?? []
        guard !panes.contains(where: { $0.id == childId }) else { return true }
        guard panes.count < Self.maxPanesPerTask else { return false }

        // Starts not-visible: whether this task is the currently selected
        // one is `MainAreaView`'s business, not this store's — it corrects
        // this via `syncVisibility()`, triggered by `version` changing.
        let host = makeHost(cwd, command) { [weak self] _ in
            self?.close(taskId: taskId, childId: childId)
        }
        host.isVisible = false
        panes.append(ChildPane(id: childId, taskId: taskId, label: label, host: host))
        panesByTask[taskId] = panes
        version += 1
        return true
    }

    /// Removes `childId`'s pane, if it exists. Idempotent — a second close,
    /// or a close racing the surface's own process-exit teardown, is a
    /// no-op rather than an error.
    public func close(taskId: Int64, childId: String) {
        guard var panes = panesByTask[taskId], let index = panes.firstIndex(where: { $0.id == childId }) else { return }
        panes.remove(at: index)
        panesByTask[taskId] = panes.isEmpty ? nil : panes
        version += 1
    }

    /// Removes every pane for `taskId` at once — used when the task's own
    /// terminal closes (`MainAreaView.closeHost`) or the task itself goes
    /// away (`MainAreaView.purgeHosts`), since a child pane never outlives
    /// the parent terminal it belongs to.
    public func closeAll(taskId: Int64) {
        guard panesByTask.removeValue(forKey: taskId) != nil else { return }
        version += 1
    }
}
