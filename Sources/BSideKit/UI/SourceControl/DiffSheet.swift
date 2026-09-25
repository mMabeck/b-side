import AppKit
import SwiftUI

/// Sheet showing a single file's unified diff. Takes only plain
/// `String`/`Bool` inputs and a bare callback — no git types — so it can be
/// previewed and unit tested (via ``UnifiedDiffRenderer``) without a
/// repository. Themed like the rest of the app's chrome; see
/// `TaskCreationView` for the same `.themedWindow`/`themedButton` convention.
struct DiffSheet: View {
    /// File path or name shown as the sheet's title.
    let title: String
    /// Kind label shown under the title: "Staged", "Unstaged", or
    /// "Committed on branch".
    let subtitle: String
    /// Unified diff text. Ignored when `isBinary` is true.
    let diffText: String
    let isBinary: Bool
    /// Whether `diffText` was capped before reaching this view (e.g. a very
    /// large file); shows a banner rather than implying the diff is complete.
    let isTruncated: Bool
    /// Shows an "Open in Editor" button when non-nil.
    var onOpenInEditor: (() -> Void)?

    @ObservedObject private var theme: GhosttyResolvedTheme = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isTruncated {
                truncationBanner
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(theme.palette.separator)
                .frame(height: 1)

            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(theme.palette.windowBackground)
        // The sheet gets its own `NSWindow`, so it needs the palette applied
        // to that window too — not just a themed SwiftUI background — or the
        // system-drawn text inside it renders in light `aqua` over this dark
        // background.
        .themedWindow(theme.palette)
        .onExitCommand { dismiss() }
    }

    /// Rendered lazily and only when there is text to show; not cached
    /// across body re-evaluations, since ``UnifiedDiffRenderer`` is built to
    /// stay fast even at 10k+ lines.
    private var renderedDiff: NSAttributedString {
        guard !isBinary, !diffText.isEmpty else { return NSAttributedString() }
        return UnifiedDiffRenderer.render(diffText, palette: theme.palette)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isBinary {
            centeredMessage("Binary file — no text diff")
        } else if diffText.isEmpty {
            centeredMessage("No changes")
        } else {
            DiffTextView(attributedText: renderedDiff, palette: theme.palette)
        }
    }

    private func centeredMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(theme.palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.windowBackground)
    }

    private var truncationBanner: some View {
        Text("Diff truncated — showing a partial view of a very large change.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(theme.palette.statusNeedsAttention.opacity(0.18))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            if let onOpenInEditor {
                themedButton("Open in Editor", isPrimary: false, action: onOpenInEditor)
            }
            themedButton("Done", isPrimary: true, isDefaultAction: true) { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func themedButton(
        _ title: String,
        isPrimary: Bool,
        isDefaultAction: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isPrimary ? theme.palette.selectionForeground : theme.palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isPrimary ? theme.palette.accent : theme.palette.elevatedSurfaceBackground)
                )
        }
        .buttonStyle(.plain)

        return Group {
            if isDefaultAction {
                button.keyboardShortcut(.defaultAction)
            } else {
                button
            }
        }
    }
}
