import SwiftUI

/// Never `HSplitView`/`VSplitView` (AppKit `updateConstraints` crash); every surface stays mounted and only the shown one is visible.
struct TaskTerminalAreaView: View {
    var store: ProjectsStore
    var host: TerminalSurfaceHost
    var taskID: Int64
    var focusedTaskID: FocusState<Int64?>.Binding

    var isExited: Bool = false
    var onResume: (() -> Void)? = nil

    var isSelected: Bool = true

    var body: some View {
        let allRuns = store.subagentFeed.runs(forTask: taskID)
        let shownChildID = store.subagentSwap.shownChildID(forTask: taskID)
        let runs = store.subagentStripBatches.visibleRuns(forTask: taskID, allRuns: allRuns, swappedInChildID: shownChildID)
        let panes = store.subagentPanes.panes(forTask: taskID)

        VStack(spacing: 0) {
            if !runs.isEmpty {
                SubagentStripView(runs: runs, viewedChildId: shownChildID, onSelect: handle, onAnyClick: focusShownSurface)
            }

            ZStack {
                Group {
                    if isExited, let onResume {
                        PiSessionEndedView(taskID: taskID, focusedTaskID: focusedTaskID, onResume: onResume)
                    } else {
                        TerminalHostView(host: host)
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
        // Re-renders on the passage of time: a finished card's linger expiring changes no observed state.
        .onChange(of: store.stripTickToken) { _, _ in }
        // Follow with real focus only when this task is on screen, or a hidden task's child closing steals focus.
        .onChange(of: shownChildID) { _, newValue in
            guard isSelected else { return }
            if let newValue, let pane = panes.first(where: { $0.id == newValue }) {
                pane.host.focus()
                host.resignFocus()
            } else {
                host.focus()
                for pane in panes { pane.host.resignFocus() }
            }
        }
    }

    private func handle(_ hit: SubagentStripMouseParser.HitTestResult) {
        // Resolved at click time, not from a snapshot.
        let livePaneIDs = Set(store.subagentPanes.panes(forTask: taskID).map(\.id))
        switch SubagentStripClickResolver.resolve(hit, livePaneIDs: livePaneIDs) {
        case .showMain:
            store.subagentSwap.showMain(forTask: taskID)
        case .toggle(let childId):
            store.subagentSwap.toggle(childId: childId, forTask: taskID)
        case .highlight(let childId):
            store.subagentSwap.highlight(childId: childId, forTask: taskID)
        }
    }

    /// Called for every press: a real Ghostty surface would otherwise hold focus with nothing to type into.
    private func focusShownSurface() {
        let shownChildID = store.subagentSwap.shownChildID(forTask: taskID)
        let panes = store.subagentPanes.panes(forTask: taskID)
        if let shownChildID, let pane = panes.first(where: { $0.id == shownChildID }) {
            pane.host.focus()
            host.resignFocus()
        } else {
            host.focus()
            for pane in panes { pane.host.resignFocus() }
        }
    }
}
