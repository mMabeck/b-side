import SwiftUI

private struct TitleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// One child run rendered as a card: real text layout and truncation instead
/// of the terminal original's box-drawing characters, matching native-
/// rewrite.md §6. Colour is driven entirely by the user's resolved Ghostty
/// theme so the sidebar reads as continuous with the terminal beside it.
struct SubagentCardView: View {
    let run: ChildRun
    @ObservedObject var theme: GhosttyResolvedTheme

    @State private var isExpanded = false
    @State private var titleSize: CGSize = .zero

    private static let tailLineCount = 4
    /// Horizontal distance from the card's left edge to where the title
    /// chip starts, clearing the rounded corner and leaving the short
    /// `┌─` lead-in segment of stroke visible before it.
    private static let titleLeadIn: CGFloat = 16
    private static let titleMaxWidth: CGFloat = 220

    private var accentColor: Color { theme.palette.accent }
    private var foregroundColor: Color { theme.palette.textPrimary }
    private var dimColor: Color { theme.palette.textSecondary }
    private var backgroundColor: Color { theme.palette.elevatedSurfaceBackground.opacity(0.6) }

    /// The title patch must be fully opaque. A translucent one lets the border
    /// stroke underneath show through the text, which reads as strikethrough.
    private var titleMaskColor: Color { theme.palette.elevatedSurfaceBackground }

    private var isFinished: Bool { run.state == .completed || run.state == .failed }

    private var borderColor: Color {
        switch run.state {
        case .blocked: return theme.palette.statusNeedsAttention
        case .failed: return theme.palette.statusError
        case .active: return accentColor
        case .completed: return dimColor.opacity(0.5)
        }
    }

    private var visibleLines: [String] {
        isExpanded || run.toolLines.count <= Self.tailLineCount
            ? run.toolLines
            : Array(run.toolLines.suffix(Self.tailLineCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolLinesView
            statusFooter
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: run.state == .blocked ? 2 : 1)
        }
        .overlay(alignment: .topLeading) {
            titleOverlay
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if run.toolLines.count > Self.tailLineCount {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
        }
    }

    /// Inlaid in the top border stroke rather than floating above it: a
    /// background-coloured patch sized to the title's own measured bounds
    /// breaks the stroke drawn underneath, and the title is centred on that
    /// break so the line visibly resumes past it.
    private var titleOverlay: some View {
        HStack(spacing: 4) {
            Text(run.agent)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(accentColor)
            Text("· \(run.taskLabel)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(dimColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: Self.titleMaxWidth, alignment: .leading)
        .padding(.horizontal, 6)
        .background(
            GeometryReader { proxy in
                titleMaskColor.preference(key: TitleSizeKey.self, value: proxy.size)
            }
        )
        .fixedSize(horizontal: false, vertical: true)
        .onPreferenceChange(TitleSizeKey.self) { titleSize = $0 }
        .offset(x: Self.titleLeadIn, y: -titleSize.height / 2)
    }

    private var toolLinesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let openingLine = run.openingLine, !openingLine.isEmpty {
                Text(openingLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(dimColor)
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
            }
            if run.toolLines.isEmpty {
                Text("no tool calls yet")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(dimColor)
            } else {
                ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                    Text("→ \(line)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isFinished ? dimColor : foregroundColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var statusFooter: some View {
        TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
            HStack(spacing: 6) {
                statusGlyph
                Text(statusLabel)
                    .font(.system(.caption2, design: .monospaced, weight: run.state == .blocked ? .bold : .regular))
                    .foregroundStyle(run.state == .blocked ? theme.palette.statusNeedsAttention : dimColor)
                Text(RunStatisticsFormatter.formatDuration(elapsed(at: context.date)))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(dimColor)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            let statsLine = RunStatisticsFormatter.format(run.statistics)
            if !statsLine.isEmpty && statsLine != "0 turns" {
                Text(statsLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(dimColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var statusGlyph: some View {
        Group {
            switch run.state {
            case .active:
                ProgressView()
                    .controlSize(.mini)
            case .blocked:
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(theme.palette.statusNeedsAttention)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(dimColor)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.palette.statusError)
            }
        }
        .frame(width: 14)
    }

    private var statusLabel: String {
        switch run.state {
        case .active: return "working"
        case .blocked: return "blocked — needs you"
        case .completed: return "finished"
        case .failed: return "failed"
        }
    }

    private func elapsed(at date: Date) -> TimeInterval {
        (run.endedAt ?? date).timeIntervalSince(run.startedAt)
    }
}
