import AppKit
import SwiftUI

struct DiffSheet: View {
    let title: String
    let subtitle: String
    let diffText: String
    let isBinary: Bool
    let isTruncated: Bool
    var errorMessage: String?
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
        .closesSheetOnCommandW { dismiss() }
    }

    private var renderedDiff: NSAttributedString {
        guard !isBinary, !diffText.isEmpty else { return NSAttributedString() }
        return UnifiedDiffRenderer.render(diffText, palette: theme.palette)
    }


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
