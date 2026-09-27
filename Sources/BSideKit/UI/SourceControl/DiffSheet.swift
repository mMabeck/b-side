import AppKit
import SwiftUI

/// Sheet showing a single file's unified diff. Takes only plain
/// `String`/`Bool` inputs and a bare callback — no git types — so it can be
/// previewed and unit tested (via ``UnifiedDiffRenderer``) without a
/// repository. Themed like the rest of the app's chrome; see
/// `TaskCreationView` for the same `.themedWindow`/`themedButton` convention.
struct DiffSheet: View {
    let title: String
    /// "Staged", "Unstaged", or "Committed on branch".
    let subtitle: String
    /// Ignored when `isBinary` is true.
    let diffText: String
    let isBinary: Bool
    /// Shows a banner rather than implying the diff is complete.
    let isTruncated: Bool
    /// Shown instead of `diffText`/"No changes", which would otherwise misrepresent a load failure as clean.
    var errorMessage: String?
    /// Shows an "Open in Editor" button when non-nil.
    var onOpenInEditor: (() -> Void)?

    @ObservedObject private var theme: GhosttyResolvedTheme = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if isTruncated {
                        truncationBanner
                    }
                }
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItemGroup(placement: .confirmationAction) {
                        if let onOpenInEditor {
                            Button("Open in Editor", action: onOpenInEditor)
                        }
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 480)
        // Its own `NSWindow` needs the palette applied directly, or system-drawn text renders in light `aqua`.
        .themedWindow(theme.palette)
        .onExitCommand { dismiss() }
    }

    /// Not cached across body re-evaluations, since ``UnifiedDiffRenderer`` stays fast even at 10k+ lines.
    private var renderedDiff: NSAttributedString {
        guard !isBinary, !diffText.isEmpty else { return NSAttributedString() }
        return UnifiedDiffRenderer.render(diffText, palette: theme.palette)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            centeredMessage("Couldn’t load diff: \(errorMessage)")
        } else if isBinary {
            centeredMessage("Binary file — no text diff")
        } else if diffText.isEmpty {
            centeredMessage("No changes")
        } else {
            DiffTextView(attributedText: renderedDiff, palette: theme.palette)
        }
    }

    private func centeredMessage(_ message: String) -> some View {
        SheetCenteredMessage(message: message, palette: theme.palette)
    }

    private var truncationBanner: some View {
        SheetTruncationBanner(palette: theme.palette)
    }

}
