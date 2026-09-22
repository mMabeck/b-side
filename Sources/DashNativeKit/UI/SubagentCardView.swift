import SwiftUI

/// One child run rendered as a card: real text layout and truncation instead
/// of the terminal original's box-drawing characters, matching native-
/// rewrite.md §6. Colour is driven entirely by the user's resolved Ghostty
/// theme so the sidebar reads as continuous with the terminal beside it.
struct SubagentCardView: View {
    let run: ChildRun
    @ObservedObject var theme: GhosttyResolvedTheme

    @State private var isExpanded = false

    private static let tailLineCount = 4

    private var accentColor: Color { theme.accent ?? .accentColor }
    private var foregroundColor: Color { theme.foreground ?? .primary }
    private var dimColor: Color { theme.secondaryForeground ?? .secondary }
    private var backgroundColor: Color { (theme.background ?? Color(nsColor: .textBackgroundColor)).opacity(0.6) }

    private var isFinished: Bool { run.state == .completed || run.state == .failed }

    private var borderColor: Color {
        switch run.state {
        case .blocked: return .orange
        case .failed: return .red
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
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: run.state == .blocked ? 2 : 1)
        }
        .overlay(alignment: .top) {
            titleOverlay
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if run.toolLines.count > Self.tailLineCount {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
        }
    }

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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(backgroundColor)
        .offset(y: -10)
        .padding(.horizontal, 10)
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
                    .foregroundStyle(run.state == .blocked ? Color.orange : dimColor)
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
                    .foregroundStyle(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(dimColor)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
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
