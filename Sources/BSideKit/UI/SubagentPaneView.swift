import SwiftUI

/// One task's terminal area: the parent's `TerminalHostView` alone, filling
/// the space, while it has no live subagent panes; or a native horizontal
/// split \u2014 parent on the left (~60%), children stacked vertically on the
/// right, equal heights \u2014 once `SubagentPaneStore` has any for this task
/// (native-rewrite.md \u00a7"The chosen design: native splits, plus cards").
/// Pane membership updates automatically as panes open/close since it reads
/// `store.subagentPanes` directly rather than caching a snapshot.
///
/// The parent's `TerminalHostView` sits at one stable position in the view
/// tree \u2014 the first child of the same `HSplitView` in both the empty and
/// non-empty cases \u2014 rather than living in two branches of an `if`/`else`.
/// Only the children column is conditional. SwiftUI would otherwise treat
/// the parent host as a structurally different view across the two branches
/// and tear down/rebuild its underlying `NSView` whenever the first pane
/// opens or the last one closes, which can drop first responder out from
/// under whatever was focused.
struct TaskTerminalAreaView: View {
    var store: ProjectsStore
    var host: TerminalSurfaceHost
    var taskID: Int64
    var focusedTaskID: FocusState<Int64?>.Binding
    @Binding var focusedChildID: String?

    var body: some View {
        let panes = store.subagentPanes.panes(forTask: taskID)
        GeometryReader { proxy in
            HSplitView {
                TerminalHostView(host: host, focusedTaskID: focusedTaskID, taskID: taskID)
                    .frame(minWidth: 240, idealWidth: panes.isEmpty ? proxy.size.width : proxy.size.width * 0.6)
                if !panes.isEmpty {
                    VSplitView {
                        ForEach(panes) { pane in
                            SubagentPaneView(store: store, taskID: taskID, pane: pane, focusedChildID: $focusedChildID)
                        }
                    }
                    .frame(minWidth: 200, idealWidth: proxy.size.width * 0.4)
                }
            }
        }
    }
}

/// One child's native pane: a slim header (agent label, a state glyph driven
/// by `SubagentFeedStore`'s run for the same child id, accent tint while
/// focused) over its own `TerminalSurfaceHost`. Deliberately mounted with no
/// `focusedTaskID` binding \u2014 unlike the parent's `TerminalHostView` \u2014 so
/// opening it never steals keyboard focus; a click (anywhere in the pane,
/// via the header's explicit `requestFocus()` or ordinary AppKit
/// click-to-focus on the terminal itself) is what focuses it.
///
/// Also deliberately has no `TerminalAlertBridge` of its own \u2014 the
/// Subagents tab's cards, backed by the same `SubagentFeedStore` run this
/// pane's header glyph reads from, already carry a child's state, so a
/// second bridge here would be redundant.
struct SubagentPaneView: View {
    var store: ProjectsStore
    var taskID: Int64
    var pane: SubagentPaneStore.ChildPane
    @Binding var focusedChildID: String?
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    private var run: ChildRun? {
        store.subagentFeed.runs(forTask: taskID).first { $0.id == pane.id }
    }

    private var isFocused: Bool { focusedChildID == pane.id }

    private var glyphColor: Color {
        switch run?.state {
        case .blocked: return theme.palette.statusNeedsAttention
        case .failed: return theme.palette.statusError
        case .completed: return theme.palette.textSecondary
        case .active, .none: return theme.palette.accent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHostView(host: pane.host)
        }
        .overlay(
            Rectangle()
                .strokeBorder(isFocused ? theme.palette.accent : Color.clear, lineWidth: 2)
        )
        // `simultaneousGesture` rather than `onTapGesture`: it observes a
        // click without consuming it, so a click that lands on the terminal
        // itself still reaches it (for AppKit's own click-to-focus and for
        // text selection) while still updating which pane reads as focused.
        .simultaneousGesture(TapGesture().onEnded { focusedChildID = pane.id })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(glyphColor)
                .frame(width: 6, height: 6)
            Text(pane.label)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isFocused ? theme.palette.accent.opacity(0.18) : theme.palette.elevatedSurfaceBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedChildID = pane.id
            pane.host.state.requestFocus()
        }
    }
}
