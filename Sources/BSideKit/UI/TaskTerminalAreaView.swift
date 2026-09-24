import SwiftUI

/// One task's terminal area: the subagent card strip (only while the task
/// has runs to show), above exactly one live surface — the parent's
/// `TerminalHostView`, or one child's, per `ProjectsStore.subagentSwap`.
/// Native splits were removed (they crashed the app during an AppKit
/// `updateConstraints` pass — see native-rewrite.md); this is a plain
/// `VStack`/`ZStack`, never an `HSplitView`/`VSplitView`.
///
/// Every surface — parent and every live child pane — stays mounted in the
/// `ZStack` at all times; only the shown one is visible (opacity/hit-testing
/// toggle, the same "stays mounted, marked not-visible" discipline
/// `MainAreaView` itself uses for hidden tasks). Swapping which one is shown
/// also moves real keyboard focus to it — see the `onChange` below.
struct TaskTerminalAreaView: View {
    var store: ProjectsStore
    var host: TerminalSurfaceHost
    var taskID: Int64
    var focusedTaskID: FocusState<Int64?>.Binding

    /// Whether this task's Pi process has exited on its own; when `true`
    /// (and `onResume` is set), `PiSessionEndedView` replaces the parent's
    /// `TerminalHostView` in the same slot — see `MainAreaView`'s
    /// `exitedTaskIDs`.
    var isExited: Bool = false
    var onResume: (() -> Void)? = nil

    var body: some View {
        let allRuns = store.subagentFeed.runs(forTask: taskID)
        let runs = store.subagentStripBatches.visibleRuns(forTask: taskID, allRuns: allRuns)
        let panes = store.subagentPanes.panes(forTask: taskID)
        let shownChildID = store.subagentSwap.shownChildID(forTask: taskID)

        VStack(spacing: 0) {
            if !runs.isEmpty {
                SubagentStripView(runs: runs, viewedChildId: shownChildID) { hit in
                    handle(hit, panes: panes)
                }
            }

            ZStack {
                Group {
                    if isExited, let onResume {
                        PiSessionEndedView(taskID: taskID, focusedTaskID: focusedTaskID, onResume: onResume)
                    } else {
                        TerminalHostView(host: host, focusedTaskID: focusedTaskID, taskID: taskID)
                    }
                }
                .opacity(shownChildID == nil ? 1 : 0)
                .allowsHitTesting(shownChildID == nil)

                ForEach(panes) { pane in
                    TerminalHostView(host: pane.host)
                        .opacity(shownChildID == pane.id ? 1 : 0)
                        .allowsHitTesting(shownChildID == pane.id)
                }
            }
        }
        .onChange(of: shownChildID) { _, newValue in
            if let newValue, let pane = panes.first(where: { $0.id == newValue }) {
                pane.host.state.requestFocus()
            } else {
                host.state.requestFocus()
            }
        }
    }

    private func handle(_ hit: SubagentStripMouseParser.HitTestResult, panes: [SubagentPaneStore.ChildPane]) {
        switch hit {
        case .mainHint:
            store.subagentSwap.showMain(forTask: taskID)
        case .card(let childId):
            if panes.contains(where: { $0.id == childId }) {
                store.subagentSwap.toggle(childId: childId, forTask: taskID)
            } else {
                // A headless, card-only child: highlight it in the strip
                // without disturbing whatever the main area already shows.
                store.subagentSwap.highlight(childId: childId, forTask: taskID)
            }
        }
    }
}
