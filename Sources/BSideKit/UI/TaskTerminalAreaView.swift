import SwiftUI

/// The subagent card strip above exactly one live surface — the parent's or
/// one child's, per `ProjectsStore.subagentSwap`. A plain `VStack`/`ZStack`,
/// never `HSplitView`/`VSplitView` (AppKit `updateConstraints` crash).
///
/// Every surface stays mounted in the `ZStack`; only the shown one is
/// visible (same discipline `MainAreaView` uses for hidden tasks). Swapping which is shown also moves real keyboard focus.
struct TaskTerminalAreaView: View {
    var store: ProjectsStore
    var host: TerminalSurfaceHost
    var taskID: Int64
    var focusedTaskID: FocusState<Int64?>.Binding

    /// When `true` (with `onResume` set), `PiSessionEndedView` replaces `TerminalHostView` in the same slot.
    var isExited: Bool = false
    var onResume: (() -> Void)? = nil

    /// The auto-return-on-close `onChange` below must not steal focus into a hidden task.
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
        // Forces a re-render purely on the passage of time: a finished
        // card's linger expiring changes no other observed state.
        .onChange(of: store.stripTickToken) { _, _ in }
        // A shown child's surface closing swaps `shownChildID` out from under
        // this view; only follow with real focus when this task is on screen,
        // or a hidden background task's child closing would steal focus.
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
        // Resolved fresh at click time, not from a snapshot when the closure was installed.
        let livePaneIDs = Set(store.subagentPanes.panes(forTask: taskID).map(\.id))
        switch SubagentStripClickResolver.resolve(hit, livePaneIDs: livePaneIDs) {
        case .showMain:
            store.subagentSwap.showMain(forTask: taskID)
        case .toggle(let childId):
            store.subagentSwap.toggle(childId: childId, forTask: taskID)
        case .highlight(let childId):
            // A headless, card-only child: highlight without disturbing the main area.
            store.subagentSwap.highlight(childId: childId, forTask: taskID)
        }
    }

    /// Called for every press on the strip, hit or not — a real Ghostty
    /// surface would otherwise hold keyboard focus with nothing to type
    /// into. Resolved live, after `handle`, so a swap also focuses the newly shown surface.
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
