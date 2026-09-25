import SwiftUI

/// The four task states from native-rewrite.md §5, and how the sidebar's
/// fixed-width status dot renders each of them.
public enum TaskStatus: Hashable, Sendable {
    case running
    case needsAttention
    case idle
    case finished

    /// Derives a task's status from signals already wired into the sidebar —
    /// no hook-based detection exists yet (see native-rewrite.md §5), so this
    /// is a provisional stand-in until the agent lifecycle server lands.
    ///
    /// `merged` takes priority: a task whose branch is already merged is
    /// "finished" regardless of whatever else is going on in its worktree.
    ///
    /// `needsAttention` defaults to `false` for callers with no opinion
    /// (existing tests, `ProjectsStore.taskIDsNeedingAttention` not wired in
    /// yet) — it folds a task's terminal having raised a question alert
    /// (see `ProjectsStore.handleTerminalAlert`) into the same tier as
    /// `isBlocked`/`isVanished`.
    ///
    /// `busy` defaults to `false` and folds the parent Pi agent loop's own
    /// `POST /agent/{taskId}/busy`/`idle` reports (`ProjectsStore.busyTaskIDs`,
    /// via `SubagentEventServer`) into the same "running" tier as a live
    /// subagent child — the sidebar dot shouldn't read idle just because no
    /// child subagent happens to be active right now.
    public static func derive(
        merged: Bool,
        isBlocked: Bool,
        isVanished: Bool,
        activeChildCount: Int,
        needsAttention: Bool = false,
        busy: Bool = false
    ) -> TaskStatus {
        if merged { return .finished }
        if isBlocked || isVanished || needsAttention { return .needsAttention }
        if busy || activeChildCount > 0 { return .running }
        return .idle
    }

    /// The dot's fill colour from the palette. "Needs attention" reads as
    /// most prominent per native-rewrite.md §5 — it borrows the palette's
    /// most attention-grabbing status colour, the other three progressively
    /// quieter.
    public func color(in palette: BSidePalette) -> Color {
        switch self {
        case .running: palette.statusRunning
        case .needsAttention: palette.statusNeedsAttention
        case .idle: palette.textDisabled
        case .finished: palette.statusSuccess
        }
    }
}

/// Layout constants for the task row's leading status column. The column
/// width is reserved unconditionally — every task title starts at the same
/// x whether or not its status has a visible dot.
public enum TaskRowLayout {
    public static let statusDotColumnWidth: CGFloat = 14
    public static let statusDotDiameter: CGFloat = 6

    /// Always returns the same width regardless of `status` — the
    /// alignment invariant the reserved column exists to guarantee.
    public static func dotColumnWidth(for status: TaskStatus?) -> CGFloat {
        statusDotColumnWidth
    }
}
