import AppKit
import SwiftUI

private struct StatusDotReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

extension EnvironmentValues {
    public var statusDotReduceMotion: Bool {
        get { self[StatusDotReduceMotionKey.self] }
        set { self[StatusDotReduceMotionKey.self] = newValue }
    }
}

/// Merge state is deliberately not an input; the separate "Merged" pill shows it.
public enum TaskStatus: Hashable, Sendable {
    case question
    case running
    case unread
    case read
    case inactive

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

public enum TaskRowLayout {
    public static let statusDotColumnWidth: CGFloat = 14
    public static let statusDotDiameter: CGFloat = 8

    public static func dotColumnWidth(for status: TaskStatus?) -> CGFloat {
        statusDotColumnWidth
    }
}

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
            // Discrete steps, not `repeatForever`: that redraws the glass sidebar at display rate and outlives the running state.
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
