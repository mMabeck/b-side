import SwiftUI

/// One row in the Source Control sidebar's file list: a kind badge letter, the
/// file name, its dimmed containing directory, and either +N/-N line counts
/// or (on hover) stage/unstage/discard buttons in their place.
struct SourceControlRowView: View {
    let row: SourceControlStore.Row
    let palette: BSidePalette
    var onStage: (() -> Void)?
    var onUnstage: (() -> Void)?
    var onDiscard: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.badgeLetter(row.kind))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Self.badgeColor(row.kind, palette: palette))
                .frame(width: 14, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.directory.isEmpty {
                    Text(row.directory)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textDisabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            if isHovering && (onStage != nil || onUnstage != nil || onDiscard != nil) {
                hoverButtons
            } else {
                lineCounts
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.kindDescription(row.kind)), \(row.path)")
    }

    @ViewBuilder
    private var lineCounts: some View {
        if row.isBinary {
            Text("bin")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textDisabled)
        } else {
            HStack(spacing: 4) {
                if let added = row.linesAdded, added > 0 {
                    Text("+\(added)").foregroundStyle(palette.statusSuccess)
                }
                if let removed = row.linesRemoved, removed > 0 {
                    Text("\u{2212}\(removed)").foregroundStyle(palette.statusError)
                }
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }

    private var hoverButtons: some View {
        HStack(spacing: 4) {
            if let onStage {
                iconButton("plus", label: "Stage \(row.displayName)", action: onStage)
            }
            if let onUnstage {
                iconButton("minus", label: "Unstage \(row.displayName)", action: onUnstage)
            }
            if let onDiscard {
                iconButton("arrow.uturn.backward", label: "Discard changes to \(row.displayName)", action: onDiscard)
            }
        }
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textSecondary)
        .accessibilityLabel(label)
    }

    static func badgeLetter(_ kind: GitCLI.FileChange.Kind) -> String {
        switch kind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "C"
        }
    }

    static func badgeColor(_ kind: GitCLI.FileChange.Kind, palette: BSidePalette) -> Color {
        switch kind {
        case .added, .untracked:
            return palette.statusSuccess
        case .deleted, .conflicted:
            return palette.statusError
        case .modified, .renamed, .typeChanged:
            return palette.accent
        }
    }

    static func kindDescription(_ kind: GitCLI.FileChange.Kind) -> String {
        switch kind {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .typeChanged: return "Type changed"
        case .untracked: return "Untracked"
        case .conflicted: return "Conflicted"
        }
    }
}
