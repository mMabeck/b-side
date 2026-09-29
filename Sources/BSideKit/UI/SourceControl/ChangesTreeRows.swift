import SwiftUI

enum ChangesRowStyle {
    static let rowHeight: CGFloat = 22

    static func statusColor(_ kind: GitCLI.FileChange.Kind, palette: BSidePalette) -> Color {
        switch kind {
        case .added, .untracked: return palette.statusSuccess
        case .deleted, .conflicted: return palette.statusError
        case .modified, .renamed, .typeChanged: return palette.statusRunning
        }
    }
}

struct ChangesFolderRow: View {
    let folder: ChangesTreeNode.Folder
    let isExpanded: Bool
    let palette: BSidePalette
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 12)
            Text(folder.displayName)
                .font(.callout)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(minHeight: ChangesRowStyle.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.displayName), folder")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
    }
}

struct ChangesFileRow: View {
    let file: ChangesTreeFile
    let palette: BSidePalette

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 12, height: 1)
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
            Text((file.path as NSString).lastPathComponent)
                .font(.callout)
                .strikethrough(file.kind == .deleted)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            counts
            Text(SourceControlRowView.badgeLetter(file.kind))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 12, alignment: .trailing)
        }
        .frame(minHeight: ChangesRowStyle.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusColor: Color { ChangesRowStyle.statusColor(file.kind, palette: palette) }

    @ViewBuilder
    private var counts: some View {
        if file.isBinary {
            Text("bin")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textDisabled)
        } else {
            HStack(spacing: 3) {
                if let added = file.linesAdded, added > 0 {
                    Text("+\(added)").foregroundStyle(palette.statusSuccess)
                }
                if let removed = file.linesRemoved, removed > 0 {
                    Text("\u{2212}\(removed)").foregroundStyle(palette.statusError)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .opacity(0.8)
        }
    }

    private var accessibilityLabel: String {
        var parts = ["\(file.path), \(SourceControlRowView.kindDescription(file.kind).lowercased())"]
        if file.isBinary {
            parts.append("binary")
        } else {
            if let added = file.linesAdded, added > 0 {
                parts.append("\(added) addition\(added == 1 ? "" : "s")")
            }
            if let removed = file.linesRemoved, removed > 0 {
                parts.append("\(removed) deletion\(removed == 1 ? "" : "s")")
            }
        }
        return parts.joined(separator: ", ")
    }
}
