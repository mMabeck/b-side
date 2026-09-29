import AppKit
import SwiftUI

/// Same intent as `accessibilityReduceMotion`, but writable, since the
/// system one is read-only.
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
/// deliberately not an input — shown by the separate "Merged" pill instead,
/// so a merged-but-still-open task can still read as unread, running, etc.
public enum TaskStatus: Hashable, Sendable {
    /// A question alert, or a blocked/vanished worktree. The palette's most attention-grabbing colour.
    case question
    /// A live subagent child or a busy parent Pi loop. Blinking amber (see `StatusDot`).
    case running
    /// Open in a tab, with output since last viewed. Blue.
    case unread
    /// Open in a tab, nothing new since last viewed. Green.
    case read
    /// Not open in any tab. Grey.
    case inactive

    /// `needsAttention`/`isBlocked`/`isVanished` outrank everything else.
    /// `busy` folds the parent Pi loop's own busy/idle reports into the same
    /// "running" tier as a live subagent child. A task not `isOpen` reads
    /// `.inactive` regardless of anything else.
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

    public func color(in palette: BSidePalette) -> Color {
        switch self {
        case .question: palette.statusNeedsAttention
        case .running: palette.statusRunning
        case .unread: palette.statusUnread
        case .read: palette.statusSuccess
        case .inactive: palette.textDisabled
        }
    }

    /// Read out ahead of the task's own name by VoiceOver.
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

/// The column width is reserved unconditionally so every task title starts at the same x.
public enum TaskRowLayout {
    public static let statusDotColumnWidth: CGFloat = 14
    public static let statusDotDiameter: CGFloat = 8

    public static func dotColumnWidth(for status: TaskStatus?) -> CGFloat {
        statusDotColumnWidth
    }
}

/// Blinks once a second while `.running`, using local view state rather than
/// a store-driven timer. Solid under Reduce Motion.
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
            // Discrete steps, not an interpolated `repeatForever` pulse: that redraws
            // the glass sidebar at display rate and outlives the running state.
            .task(id: shouldBlink) {
                isDimmed = false
                while shouldBlink, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    isDimmed.toggle()
                }
            }
            .accessibilityLabel(status.accessibilityLabel)
    }

    private var shouldBlink: Bool {
        status == .running && !statusDotReduceMotion && !systemReduceMotion
    }
}
