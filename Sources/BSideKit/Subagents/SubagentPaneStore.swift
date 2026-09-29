import Foundation

@MainActor
@Observable
public final class SubagentPaneStore {
    /// Extra children fall back to headless: the cap is about memory/pty cost, not screen space.
    public static let maxPanesPerTask = 4

    public struct ChildPane: Identifiable, Sendable {
        public let id: String
        public let taskId: Int64
        public let label: String
        public let host: TerminalSurfaceHost
    }

    public private(set) var panesByTask: [Int64: [ChildPane]] = [:]

    /// Bumped on every mutation: reference-type hosts give no cheap `Equatable` diff for `.onChange`.
    public private(set) var version = 0

    /// Many real exec surfaces spawned back-to-back crash libghostty, hence the injectable factory.
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

    public func close(taskId: Int64, childId: String) {
        guard var panes = panesByTask[taskId], let index = panes.firstIndex(where: { $0.id == childId }) else { return }
        panes.remove(at: index)
        panesByTask[taskId] = panes.isEmpty ? nil : panes
        version += 1
    }

    public func closeAll(taskId: Int64) {
        guard panesByTask.removeValue(forKey: taskId) != nil else { return }
        version += 1
    }
}
