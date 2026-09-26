import AppKit
import SwiftUI

/// Whether `StatusDot`'s "running" blink should be suppressed: the same
/// intent as the system's `EnvironmentValues.accessibilityReduceMotion`, but
/// through this app's own writable key, since the system one is read-only
/// via `.environment` and snapshot tests need to force a settled, non-
/// blinking capture. Defaults to the real Reduce Motion setting, so
/// production code with no explicit override still behaves like a proper
/// system control.
private struct StatusDotReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

extension EnvironmentValues {
    public var statusDotReduceMotion: Bool {
        get { self[StatusDotReduceMotionKey.self] }
        set { self[StatusDotReduceMotionKey.self] = newValue }
    }
}

/// The five states a task's sidebar dot can read as. Merge state is
/// deliberately not an input; it's shown by the separate "Merged" pill
/// (`SidebarView.mergedBadge`) so the two never say the same thing twice,
/// and a merged-but-still-open task can still read as unread, running, etc.
public enum TaskStatus: Hashable, Sendable {
    /// A terminal alert classified as a question, or the task's worktree is
    /// blocked/vanished. Reads as the palette's most attention-grabbing
    /// colour, an orange-red.
    case question
    /// A live subagent child or a busy parent Pi loop. Reads as a blinking
    /// amber dot (see `StatusDot`).
    case running
    /// Open in a tab, with output since it was last viewed. Reads blue.
    case unread
    /// Open in a tab, with nothing new since it was last viewed. Reads
    /// green.
    case read
    /// Not open in any tab right now. Reads grey.
    case inactive

    /// Derives a task's status from signals already wired into the sidebar —
    /// no hook-based detection exists yet (see native-rewrite.md §5), so this
    /// is a provisional stand-in until the agent lifecycle server lands.
    ///
    /// `needsAttention`/`isBlocked`/`isVanished` outrank everything else —
    /// they fold a task's terminal having raised a question alert (see
    /// `ProjectsStore.handleTerminalAlert`) into the same tier as a blocked
    /// or vanished worktree.
    ///
    /// `busy` defaults to `false` and folds the parent Pi agent loop's own
    /// `POST /agent/{taskId}/busy`/`idle` reports (`ProjectsStore.busyTaskIDs`,
    /// via `SubagentEventServer`) into the same "running" tier as a live
    /// subagent child — the sidebar dot shouldn't read idle just because no
    /// child subagent happens to be active right now.
    ///
    /// Below that: a task not open in any tab (`isOpen`) reads `.inactive`
    /// regardless of anything else, since there is nothing to be "unread"
    /// about. An open task reads `.unread` or `.read` off `isUnread`
    /// (`ProjectsStore.unreadTaskIDs`).
    public static func derive(
        isBlocked: Bool,
        isVanished: Bool,
        activeChildCount: Int,
        isOpen: Bool,
        isUnread: Bool,
        needsAttention: Bool = false,
        busy: Bool = false
    ) -> TaskStatus {
        if isBlocked || isVanished || needsAttention { return .question }
        if busy || activeChildCount > 0 { return .running }
        if !isOpen { return .inactive }
        return isUnread ? .unread : .read
    }

    /// The dot's fill colour from the palette.
    public func color(in palette: BSidePalette) -> Color {
        switch self {
        case .question: palette.statusNeedsAttention
        case .running: palette.statusRunning
        case .unread: palette.statusUnread
        case .read: palette.statusSuccess
        case .inactive: palette.textDisabled
        }
    }

    /// A short accessibility label for `StatusDot`, read out ahead of the
    /// task's own name by VoiceOver.
    public var accessibilityLabel: String {
        switch self {
        case .question: "Needs attention"
        case .running: "Running"
        case .unread: "Unread"
        case .read: "Open"
        case .inactive: "Not open"
        }
    }
}

/// Layout constants for the task row's leading status column. The column
/// width is reserved unconditionally — every task title starts at the same
/// x whether or not its status has a visible dot.
public enum TaskRowLayout {
    public static let statusDotColumnWidth: CGFloat = 14
    public static let statusDotDiameter: CGFloat = 8

    /// Always returns the same width regardless of `status` — the
    /// alignment invariant the reserved column exists to guarantee.
    public static func dotColumnWidth(for status: TaskStatus?) -> CGFloat {
        statusDotColumnWidth
    }
}

/// A task's status dot: a themed, fixed-diameter circle that blinks while
/// `.running` and reads out its status to VoiceOver. Blinking uses local
/// view state animated from `onChange(of: shouldBlink, initial: true)` rather than a store-driven timer, since
/// nothing about a running task's *data* changes once a second — only its
/// dot's opacity does. Solid (no animation) under Reduce Motion, which
/// snapshot tests also use to get a deterministic, fully-opaque capture.
public struct StatusDot: View {
    let status: TaskStatus
    let palette: BSidePalette

    @Environment(\.statusDotReduceMotion) private var statusDotReduceMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var isDimmed = false

    public init(status: TaskStatus, palette: BSidePalette) {
        self.status = status
        self.palette = palette
    }

    public var body: some View {
        let color = status.color(in: palette)
        Circle()
            .fill(color)
            .frame(width: TaskRowLayout.statusDotDiameter, height: TaskRowLayout.statusDotDiameter)
            .shadow(color: color.opacity(0.8), radius: 3)
            .shadow(color: color.opacity(0.5), radius: 5)
            .opacity(shouldBlink && isDimmed ? 0.3 : 1)
            .onChange(of: shouldBlink, initial: true) { _, isBlinking in
                if isBlinking {
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                        isDimmed = true
                    }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isDimmed = false
                    }
                }
            }
            .accessibilityLabel(status.accessibilityLabel)
    }

    private var shouldBlink: Bool {
        status == .running && !statusDotReduceMotion && !systemReduceMotion
    }
}
