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

    /// Whether `MainAreaView` currently shows this task (vs. keeping it
    /// mounted-but-hidden for another selection). The auto-return-on-close
    /// `onChange` below must not steal focus into a hidden task — see its
    /// own comment.
    var isSelected: Bool = true

    var body: some View {
        let allRuns = store.subagentFeed.runs(forTask: taskID)
        let runs = store.subagentStripBatches.visibleRuns(forTask: taskID, allRuns: allRuns)
        let panes = store.subagentPanes.panes(forTask: taskID)
        let shownChildID = store.subagentSwap.shownChildID(forTask: taskID)

        VStack(spacing: 0) {
            if !runs.isEmpty {
                SubagentStripView(runs: runs, viewedChildId: shownChildID, onSelect: handle, onAnyClick: focusShownSurface)
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
        // Auto-return on close: a shown child's surface closing swaps
        // `shownChildID` back to `nil` (or to whatever's newly shown) out
        // from under this view. Only follow that with real keyboard focus
        // when this task is the one actually on screen — otherwise a child
        // closing in a hidden, background task would steal focus away from
        // whatever the user is looking at.
        .onChange(of: shownChildID) { _, newValue in
            guard isSelected else { return }
            if let newValue, let pane = panes.first(where: { $0.id == newValue }) {
                pane.host.state.requestFocus()
            } else {
                host.state.requestFocus()
            }
        }
    }

    private func handle(_ hit: SubagentStripMouseParser.HitTestResult) {
        // Resolved fresh at click time, not from a snapshot captured when
        // this closure was installed — see `SubagentStripClickResolver`'s
        // doc comment.
        let livePaneIDs = Set(store.subagentPanes.panes(forTask: taskID).map(\.id))
        switch SubagentStripClickResolver.resolve(hit, livePaneIDs: livePaneIDs) {
        case .showMain:
            store.subagentSwap.showMain(forTask: taskID)
        case .toggle(let childId):
            store.subagentSwap.toggle(childId: childId, forTask: taskID)
        case .highlight(let childId):
            // A headless, card-only child: highlight it in the strip
            // without disturbing whatever the main area already shows.
            store.subagentSwap.highlight(childId: childId, forTask: taskID)
        }
    }

    /// Called for every press on the strip, hit or not (a gap, the label
    /// row, or a card with no live surface all reach here too) — the strip
    /// is a real Ghostty surface, so a click into it can otherwise leave it
    /// holding keyboard focus with nothing to type into. Resolves the
    /// target live, after `handle` above has had a chance to run, so a
    /// click that swaps also focuses the newly shown surface rather than
    /// the one that was shown a moment ago.
    private func focusShownSurface() {
        let shownChildID = store.subagentSwap.shownChildID(forTask: taskID)
        if let shownChildID, let pane = store.subagentPanes.panes(forTask: taskID).first(where: { $0.id == shownChildID }) {
            pane.host.state.requestFocus()
        } else {
            host.state.requestFocus()
        }
    }
}
